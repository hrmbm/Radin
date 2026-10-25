/* ReHolz HRIS forced-release Service Worker. Deploy alongside the current app HTML as ./sw.js. */
'use strict';
const RH_SW_RELEASE = 'v18-forced-release-warm-cache';
const RH_SHELL_CACHE = 'rehholz-app-shell-v18';
const RH_SCOPE_URL = new URL(self.registration.scope);

function isAppNavigation(urlValue) {
  try {
    const u = new URL(urlValue);
    if (u.origin !== RH_SCOPE_URL.origin || !u.pathname.startsWith(RH_SCOPE_URL.pathname)) return false;
    const leaf = u.pathname.slice(RH_SCOPE_URL.pathname.length);
    return leaf === '' || leaf === '/' || /^index(?:_[^/]*)?\.html$/i.test(leaf) || /^index_reholz_dashboard_employee_record.*\.html$/i.test(leaf);
  } catch (e) { return false; }
}

async function cacheFreshShell() {
  const cache = await caches.open(RH_SHELL_CACHE);
  try {
    const req = new Request(RH_SCOPE_URL.href, { cache: 'no-store', credentials: 'same-origin' });
    const res = await fetch(req);
    if (res && res.ok && res.type !== 'opaque') {
      await cache.put(RH_SCOPE_URL.href, res.clone());
      return true;
    }
  } catch (e) {
    console.warn('[ReHolz SW] Current shell is not reachable yet:', e && e.message || e);
  }
  return !!(await cache.match(RH_SCOPE_URL.href));
}

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    // Best-effort shell preparation. Dynamic APIs and private Storage are never cached here.
    try { await cacheFreshShell(); } catch (e) { console.warn('[ReHolz SW] Shell precache deferred:', e && e.message || e); }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    // Do not destroy the previous offline shell unless a shell for this worker is available.
    const hasCurrentShell = await cacheFreshShell().catch(() => false);
    if (hasCurrentShell) {
      const names = await caches.keys();
      await Promise.all(names.filter(name => name.startsWith('rehholz-app-shell-') && name !== RH_SHELL_CACHE).map(name => caches.delete(name)));
    }
    await self.clients.claim();
    // If current HTML could not be reached, retain the previous shell and allow the next online navigation to update.
    if (!hasCurrentShell) return;
    const openClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // Older releases do not understand an update message; force app pages to navigate to current HTML.
    // Do not await navigate(): activation must finish before navigation can be handled by this worker.
    for (const client of openClients) {
      if (!isAppNavigation(client.url)) continue;
      try {
        const target = new URL(client.url);
        target.searchParams.set('__reh_force_update', RH_SW_RELEASE);
        client.navigate(target.href).catch(() => {});
      } catch (e) {}
    }
  })());
});

self.addEventListener('message', event => {
  const data = event.data || {};
  if (data.type === 'SKIP_WAITING') self.skipWaiting();
  if (data.type === 'CLIENT_RELEASE') {
    try { event.source && event.source.postMessage({ type: 'REHOLZ_SW_ACK', release: RH_SW_RELEASE, clientRelease: data.release || '' }); } catch (e) {}
  }
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' || request.mode !== 'navigate' || !isAppNavigation(request.url)) return;
  event.respondWith((async () => {
    const cache = await caches.open(RH_SHELL_CACHE);
    try {
      // Network-first always prefers the deployed current release rather than stale cached HTML.
      const response = await fetch(request, { cache: 'no-store' });
      if (response && response.ok && response.type !== 'opaque') {
        try {
          await cache.put(request, response.clone());
          await cache.put(RH_SCOPE_URL.href, response.clone());
        } catch (e) {}
      }
      return response;
    } catch (e) {
      const exact = await cache.match(request);
      if (exact) return exact;
      const root = await cache.match(RH_SCOPE_URL.href);
      if (root) return root;
      return new Response('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>ReHolz HRIS offline</title><body style="font-family:system-ui;padding:24px"><h2>ReHolz HRIS</h2><p>You are offline and no cached app shell is available. Reconnect to the internet and reopen the app to receive the latest version.</p></body>', { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }, status: 503 });
    }
  })());
});
