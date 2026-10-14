'use strict';

var CACHE_NAME = 'presensi-static-v13-4';
var SHELL_CACHE = 'presensi-shell-v13-4';
var CDN_CACHE = 'presensi-cdn-v13-4';
var APP_SHELL = ['./'];

self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(SHELL_CACHE)
      .then(function (cache) {
        return cache.addAll(APP_SHELL).catch(function () {});
      })
      .then(function () {
        return self.skipWaiting();
      })
  );
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys()
      .then(function (keys) {
        return Promise.all(
          keys.filter(function (key) {
            // Pertahankan cache versi stabil v12.1.
            if (
              key === 'presensi-static-v12-1' ||
              key === 'presensi-shell-v12-1' ||
              key === 'presensi-cdn-v12-1'
            ) {
              return false;
            }

            // Hapus cache lama selain cache v13.4.
            return key.indexOf('presensi-') === 0 &&
              key !== CACHE_NAME &&
              key !== SHELL_CACHE &&
              key !== CDN_CACHE;
          }).map(function (key) {
            return caches.delete(key);
          })
        );
      })
      .then(function () {
        return self.clients.claim();
      })
  );
});

function isStaticCdn(url) {
  var host = url.hostname;
  var path = url.pathname;

  if (
    (host === 'cdn.jsdelivr.net' || host === 'unpkg.com') &&
    (
      path.indexOf('/@vladmandic/face-api@1.7.12/') >= 0 ||
      path.indexOf('/leaflet@1.9.4/') >= 0
    )
  ) {
    return true;
  }

  return false;
}

self.addEventListener('fetch', function (event) {
  var req = event.request;

  if (req.method !== 'GET') return;

  var url;

  try {
    url = new URL(req.url);
  } catch (e) {
    return;
  }

  // Navigasi halaman: jaringan terlebih dahulu,
  // gunakan cache jika jaringan gagal.
  if (
    url.origin === self.location.origin &&
    req.mode === 'navigate'
  ) {
    event.respondWith(
      fetch(req).then(function (response) {
        if (response && response.ok) {
          var copy = response.clone();

          caches.open(SHELL_CACHE)
            .then(function (cache) {
              return cache.put(req, copy);
            })
            .catch(function () {});
        }

        return response;
      }).catch(function () {
        return caches.match(req).then(function (cached) {
          return cached || caches.match('./');
        });
      })
    );

    return;
  }

  // Hanya pustaka CDN tertentu yang di-cache.
  // API dan peta tidak dimasukkan ke cache statis.
  if (!isStaticCdn(url)) return;

  event.respondWith(
    caches.open(CDN_CACHE).then(function (cache) {
      return cache.match(req).then(function (cached) {
        if (cached) return cached;

        return fetch(req).then(function (response) {
          if (
            response &&
            response.ok &&
            (response.type === 'cors' || response.type === 'basic')
          ) {
            cache.put(req, response.clone()).catch(function () {});
          }

          return response;
        });
      });
    })
  );
});
