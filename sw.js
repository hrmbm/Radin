/* ReHolz HRIS Service Worker v20. Deploy alongside index_reholz_dashboard_employee_record_v13_1.html. */
'use strict';
const RH_SW_RELEASE = 'v20-reholz-20261025-sequenced-approval-tap-photo';
const RH_EXPECTED_HTML_RELEASE = 'v13.1.0-sequenced-approval-tap-photo';
const RH_SHELL_CACHE = 'rehholz-app-shell-v20';
const RH_SCOPE_URL = new URL(self.registration.scope);
const RH_CANONICAL_APP_URL = new URL('index_reholz_dashboard_employee_record_v13_1.html', RH_SCOPE_URL);

function isAppNavigation(urlValue) {
  try {
    const u = new URL(urlValue);
    if (u.origin !== RH_SCOPE_URL.origin || !u.pathname.startsWith(RH_SCOPE_URL.pathname)) return false;
    const leaf = u.pathname.slice(RH_SCOPE_URL.pathname.length);
    return leaf === '' || leaf === '/' || /^index(?:_[^/]*)?\.html$/i.test(leaf) || /^index_reholz_dashboard_employee_record.*\.html$/i.test(leaf);
  } catch (_) { return false; }
}

function noCacheRequest(url) {
  return new Request(url, { method: 'GET', cache: 'no-store', credentials: 'same-origin', redirect: 'follow' });
}

async function fetchFreshShell(urlValue) {
  try {
    const response = await fetch(noCacheRequest(urlValue));
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
  const cache = await caches.open(RH_SHELL_CACHE);
  const candidates = [RH_CANONICAL_APP_URL.href, RH_SCOPE_URL.href];
  try {
    const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of clients) {
      if (!isAppNavigation(client.url)) continue;
      const u = new URL(client.url); u.search = ''; u.hash = '';
      if (!candidates.includes(u.href)) candidates.push(u.href);
    }
  } catch (_) {}
  let canonicalReady = false;
  for (const url of candidates) {
    const response = await fetchFreshShell(url);
    if (!response) continue;
    try {
      await cache.put(url, response.clone());
      if (url === RH_CANONICAL_APP_URL.href) {
        await cache.put(RH_SCOPE_URL.href, response.clone());
        canonicalReady = true;
      }
    } catch (e) {
      console.warn('[ReHolz SW] Could not cache shell:', e && e.message || e);
    }
  }
  return canonicalReady;
}

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    try {
      await cacheFreshShell();
    } catch (e) {
      console.warn('[ReHolz SW] Initial shell preparation failed:', e && e.message || e);
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const hasCurrentShell = await cacheFreshShell().catch(() => false);
    await self.clients.claim();
    if (!hasCurrentShell) {
      console.warn('[ReHolz SW] Canonical shell is not reachable; previous caches are retained and clients are not forced to navigate.');
      return;
    }
    const names = await caches.keys();
    await Promise.all(names.filter(name => name.startsWith('rehholz-app-shell-') && name !== RH_SHELL_CACHE).map(name => caches.delete(name)));
    const openClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of openClients) {
      if (!isAppNavigation(client.url)) continue;
      try {
        const old = new URL(client.url);
        const target = new URL(RH_CANONICAL_APP_URL.href);
        old.searchParams.forEach((value, key) => {
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
  const exact = new URL(requestUrl); exact.search = ''; exact.hash = '';
  const keys = [exact.href, RH_CANONICAL_APP_URL.href, RH_SCOPE_URL.href];
  const names = await caches.keys();
  for (const name of names.filter(n => n.startsWith('rehholz-app-shell-')).reverse()) {
    const cache = await caches.open(name);
    for (const key of keys) {
      const hit = await cache.match(key);
      if (hit) return hit;
    }
  }
  return null;
}

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' || request.mode !== 'navigate' || !isAppNavigation(request.url)) return;

  event.respondWith((async () => {
    const requested = new URL(request.url);
    const offlinePage = new Response(
      '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>ReHolz HRIS update required</title><body style="font-family:system-ui;padding:24px"><h2>ReHolz HRIS</h2><p>The latest app release is not available at its expected address yet. Reconnect, confirm the v13.1 HTML file is published beside sw.js, and reopen the app. The previous cached shell has been retained.</p></body>',
      { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }, status: 503 }
    );

    if (requested.pathname !== RH_CANONICAL_APP_URL.pathname) {
      const freshCanonical = await fetchFreshShell(RH_CANONICAL_APP_URL.href);
      if (freshCanonical) {
        try {
          const cache = await caches.open(RH_SHELL_CACHE);
          await cache.put(RH_CANONICAL_APP_URL.href, freshCanonical.clone());
          await cache.put(RH_SCOPE_URL.href, freshCanonical.clone());
        } catch (_) {}
        const target = new URL(RH_CANONICAL_APP_URL.href);
        requested.searchParams.forEach((value, key) => target.searchParams.set(key, value));
        return Response.redirect(target.href, 302);
      }
      try {
        const legacyResponse = await fetch(request, { cache: 'no-store' });
        if (legacyResponse && legacyResponse.ok && legacyResponse.type !== 'opaque') return legacyResponse;
      } catch (_) {}
      const legacyCached = await findCachedShell(request.url);
      return legacyCached || offlinePage;
    }

    try {
      const response = await fetch(request, { cache: 'no-store' });
      if (response && response.ok && response.type !== 'opaque') {
        const ct = String(response.headers.get('content-type') || '').toLowerCase();
        const body = (ct && !ct.includes('text/html')) ? '' : await response.clone().text();
        const marker = '<meta name="reholz-release" content="' + RH_EXPECTED_HTML_RELEASE + '">';
        if (body.includes(marker)) {
          try {
            const cache = await caches.open(RH_SHELL_CACHE);
            await cache.put(RH_CANONICAL_APP_URL.href, response.clone());
            await cache.put(RH_SCOPE_URL.href, response.clone());
          } catch (_) {}
          return response;
        }
      }
      const cached = await findCachedShell(request.url);
      if (cached) return cached;
      return offlinePage;
    } catch (_) {
      const cached = await findCachedShell(request.url);
      if (cached) return cached;
      return offlinePage;
    }
  })());
});
