'use strict';

/* ==========================================================================
   ReHolz HRIS Service Worker v14
   Perubahan dari v13.5:
   1. Versi cache dinaikkan (v14) agar shell lama tergantikan bersih.
   2. supabase-js (pinned @2) ikut di-cache -> boot lebih cepat & stabil.
   3. Mekanisme update eksplisit: halaman bisa mengirim {type:'SKIP_WAITING'}
      untuk aktivasi segera, dan SW menyiarkan {type:'SW_UPDATED'} ke semua
      client setelah activate (halaman boleh memakai ini untuk toast update).
   4. Foto karyawan TIDAK lewat SW (disimpan di IndexedDB oleh RHMediaCache
      dengan invalidasi faceVer) sehingga update foto selalu terdeteksi.
   5. Cache v12.1 tetap dipertahankan sebagai fallback sesuai kebijakan lama.
   ========================================================================== */

var SW_VERSION = 'v14-0';
var CACHE_NAME = 'presensi-static-v14-0';
var SHELL_CACHE = 'presensi-shell-v14-0';
var CDN_CACHE = 'presensi-cdn-v14-0';
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
            // Pertahankan cache versi stabil v12.1 (kebijakan rollback lama).
            if (
              key === 'presensi-static-v12-1' ||
              key === 'presensi-shell-v12-1' ||
              key === 'presensi-cdn-v12-1'
            ) {
              return false;
            }

            // Hapus cache lama selain cache versi aktif.
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
      .then(function () {
        // Beri tahu semua tab bahwa versi baru aktif.
        return self.clients.matchAll({ type: 'window' }).then(function (clients) {
          clients.forEach(function (client) {
            try {
              client.postMessage({
                type: 'SW_UPDATED',
                version: SW_VERSION
              });
            } catch (e) {}
          });
        });
      })
  );
});

// Halaman dapat memaksa aktivasi SW baru tanpa menunggu tab ditutup.
self.addEventListener('message', function (event) {
  var data = event.data || {};

  if (data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

function isStaticCdn(url) {
  var host = url.hostname;
  var path = url.pathname;

  if (
    (host === 'cdn.jsdelivr.net' || host === 'unpkg.com') &&
    (
      path.indexOf('/@vladmandic/face-api@1.7.12/') >= 0 ||
      path.indexOf('/@supabase/supabase-js@2') >= 0 ||
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
  // API Supabase, RPC, dan peta tidak dimasukkan ke cache statis.
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
