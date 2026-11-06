/* ReHolz HRIS Service Worker v31.
 * GitHub Pages deployment: publish this file beside index.html as sw.js.
 * The app shell is resolved from the Service Worker scope (./), never a versioned HTML filename.
 * Release compatibility is checked only with the reholz-release meta marker inside the HTML.
 */
'use strict';

const RH_SW_RELEASE = 'v31-clockout-area-lock';
const RH_EXPECTED_HTML_RELEASE = 'v13.9.9-clockout-area-lock';
const RH_SHELL_CACHE = 'rehholz-app-shell-v31';
const RH_SCOPE_URL = new URL(self.registration.scope);
// GitHub Pages serves index.html automatically at the scope directory URL.
const RH_CANONICAL_APP_URL = new URL('./', RH_SCOPE_URL);

function isAppNavigation(urlValue) {
  try {
    const u = new URL(urlValue);
    if (u.origin !== RH_SCOPE_URL.origin || !u.pathname.startsWith(RH_SCOPE_URL.pathname)) return false;
    const leaf = u.pathname.slice(RH_SCOPE_URL.pathname.length).replace(/^\//, '');
    return leaf === '' || leaf.toLowerCase() === 'index.html';
  } catch (_) { return false; }
}

function noCacheRequest(url) {
  return new Request(url, {
    method: 'GET',
    cache: 'no-store',
    credentials: 'same-origin',
    redirect: 'follow'
  });
}

async function fetchFreshShell() {
  try {
    const response = await fetch(noCacheRequest(RH_CANONICAL_APP_URL.href));
    if (!response || !response.ok || response.type === 'opaque') return null;
    const ct = String(response.headers.get('content-type') || '').toLowerCase();
    if (ct && !ct.includes('text/html')) return null;
    const body = await response.clone().text();
    const marker = '<meta name="reholz-release" content="' + RH_EXPECTED_HTML_RELEASE + '">';
    if (!body.includes(marker)) return null;
    return response;
  } catch (_) { return null; }
}

async function cacheFreshShell() {
  const response = await fetchFreshShell();
  if (!response) return false;
  try {
    const cache = await caches.open(RH_SHELL_CACHE);
    await cache.put(RH_CANONICAL_APP_URL.href, response.clone());
    await cache.put(new URL('index.html', RH_SCOPE_URL).href, response.clone());
    return true;
  } catch (e) {
    console.warn('[ReHolz SW] Could not cache current app shell:', e && e.message || e);
    return false;
  }
}

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    try { await cacheFreshShell(); }
    catch (e) { console.warn('[ReHolz SW] Shell preparation failed:', e && e.message || e); }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const hasCurrentShell = await cacheFreshShell().catch(() => false);
    await self.clients.claim();
    if (!hasCurrentShell) {
      console.warn('[ReHolz SW] The network HTML release marker does not match. Previous caches are retained; pages are not forced to navigate.');
      return;
    }
    const names = await caches.keys();
    await Promise.all(names
      .filter(name => name.startsWith('rehholz-app-shell-') && name !== RH_SHELL_CACHE)
      .map(name => caches.delete(name)));

    const openClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of openClients) {
      if (!isAppNavigation(client.url)) continue;
      try {
        const target = new URL(RH_CANONICAL_APP_URL.href);
        const current = new URL(client.url);
        current.searchParams.forEach((value, key) => {
          if (key !== '__reh_force_update') target.searchParams.set(key, value);
        });
        target.searchParams.set('__reh_force_update', RH_SW_RELEASE);
        client.navigate(target.href).catch(() => {});
      } catch (_) {}
    }
  })());
});

self.addEventListener('message', event => {
  const data = event.data || {};
  if (data.type === 'SKIP_WAITING') self.skipWaiting();
  if (data.type === 'CLIENT_RELEASE') {
    try {
      event.source && event.source.postMessage({
        type: 'REHOLZ_SW_ACK',
        release: RH_SW_RELEASE,
        clientRelease: data.release || ''
      });
    } catch (_) {}
  }
});

async function findCachedShell(requestUrl) {
  const requested = new URL(requestUrl);
  requested.search = '';
  requested.hash = '';
  const keys = [requested.href, RH_CANONICAL_APP_URL.href, new URL('index.html', RH_SCOPE_URL).href];
  const names = (await caches.keys()).filter(n => n.startsWith('rehholz-app-shell-')).reverse();
  for (const name of names) {
    const cache = await caches.open(name);
    for (const key of keys) {
      const hit = await cache.match(key);
      if (hit) return hit;
    }
  }
  return null;
}

function offlineResponse() {
  return new Response(
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>ReHolz HRIS</title><body style="font-family:system-ui;padding:24px"><h2>ReHolz HRIS</h2><p>Aplikasi belum dapat dimuat. Periksa koneksi internet dan pastikan index.html serta sw.js versi yang sesuai sudah dipublikasikan pada direktori ini. Cache aplikasi sebelumnya tetap dipertahankan.</p></body>',
    { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }, status: 503 }
  );
}

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' || request.mode !== 'navigate' || !isAppNavigation(request.url)) return;
  event.respondWith((async () => {
    try {
      // Always resolve the app from the scope directory. GitHub Pages maps ./ to index.html.
      const response = await fetch(noCacheRequest(RH_CANONICAL_APP_URL.href));
      if (response && response.ok && response.type !== 'opaque') {
        const ct = String(response.headers.get('content-type') || '').toLowerCase();
        const body = ct && !ct.includes('text/html') ? '' : await response.clone().text();
        const marker = '<meta name="reholz-release" content="' + RH_EXPECTED_HTML_RELEASE + '">';
        if (body.includes(marker)) {
          try {
            const cache = await caches.open(RH_SHELL_CACHE);
            await cache.put(RH_CANONICAL_APP_URL.href, response.clone());
            await cache.put(new URL('index.html', RH_SCOPE_URL).href, response.clone());
          } catch (_) {}
          return response;
        }
      }
    } catch (_) {}
    return (await findCachedShell(request.url)) || offlineResponse();
  })());
});
