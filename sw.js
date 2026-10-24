'use strict';

/*
 * ReHolz HRIS Service Worker v16.0
 *
 * Kebijakan cache:
 * 1. Navigasi HTML = network-first, melewati HTTP cache browser.
 *    Cache HTML aktif hanya digunakan jika jaringan gagal.
 * 2. Hanya pustaka CDN dengan versi spesifik yang di-cache.
 * 3. Supabase RPC/REST/Auth/Storage, foto, URL bertanda tangan,
 *    tile peta, dan request yang tidak masuk daftar tidak di-cache.
 * 4. Cache menggunakan versi. Cache aplikasi lama dibersihkan saat
 *    aktivasi, kecuali cache v12.1 yang dipertahankan sebagai cadangan.
 */

var SW_VERSION = 'v16-0';
var CACHE_PREFIX = 'presensi-';
var CACHE_NAME = 'presensi-static-v16-0';
var SHELL_CACHE = 'presensi-shell-v16-0';
var CDN_CACHE = 'presensi-cdn-v16-0';
var APP_SHELL_URL = new URL('./', self.registration.scope).href;
var MAX_CDN_ENTRIES = 48;

var ROLLBACK_CACHES = [
  'presensi-static-v12-1',
  'presensi-shell-v12-1',
  'presensi-cdn-v12-1'
];

function isRollbackCache(name) {
  return ROLLBACK_CACHES.indexOf(name) !== -1;
}

function makeNoStoreRequest(request) {
  try {
    return new Request(request, { cache: 'no-store' });
  } catch (e) {
    return request;
  }
}

function isPinnedImmutableCdn(url) {
  var host = url.hostname;
  var path = url.pathname;

  if (
    host !== 'cdn.jsdelivr.net' &&
    host !== 'unpkg.com'
  ) {
    return false;
  }

  // Hanya pustaka dengan versi spesifik yang boleh di-cache.
  // Supabase JS @2 tidak dimasukkan karena versinya mengambang.
  if (
    path.indexOf(
      '/npm/@vladmandic/face-api@1.7.12/'
    ) >= 0
  ) {
    return true;
  }

  if (
    path.indexOf('/npm/leaflet@1.9.4/') >= 0
  ) {
    return true;
  }

  return false;
}

function trimCdnCache(cache) {
  return cache.keys()
    .then(function (keys) {
      if (keys.length <= MAX_CDN_ENTRIES) {
        return;
      }

      // Hapus entri paling lama saat batas cache terlampaui.
      var removeCount = keys.length - MAX_CDN_ENTRIES;

      return Promise.all(
        keys.slice(0, removeCount).map(function (request) {
          return cache.delete(request);
        })
      );
    })
    .catch(function () {});
}

/* =========================================================
   INSTALL
   Ambil shell terbaru dari jaringan jika tersedia.
   ========================================================= */

self.addEventListener('install', function (event) {
  event.waitUntil((async function () {
    try {
      var response = await fetch(
        new Request(APP_SHELL_URL, {
          method: 'GET',
          credentials: 'same-origin',
          cache: 'reload'
        })
      );

      if (
        response &&
        response.ok &&
        response.type !== 'opaque'
      ) {
        var cache = await caches.open(SHELL_CACHE);
        await cache.put(
          APP_SHELL_URL,
          response.clone()
        );
      }
    } catch (e) {
      // Instalasi masih boleh berlanjut jika jaringan gagal.
    }

    // Aktifkan versi baru tanpa menunggu tab lama ditutup.
    await self.skipWaiting();
  })());
});

/* =========================================================
   ACTIVATE
   Pertahankan cache versi aktif dan cadangan v12.1.
   ========================================================= */

self.addEventListener('activate', function (event) {
  event.waitUntil((async function () {
    var keys = await caches.keys();

    await Promise.all(
      keys.map(function (key) {
        if (key.indexOf(CACHE_PREFIX) !== 0) {
          return Promise.resolve(false);
        }

        if (
          key === CACHE_NAME ||
          key === SHELL_CACHE ||
          key === CDN_CACHE
        ) {
          return Promise.resolve(false);
        }

        if (isRollbackCache(key)) {
          return Promise.resolve(false);
        }

        return caches.delete(key);
      })
    );

    await self.clients.claim();

    var clients = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true
    });

    clients.forEach(function (client) {
      try {
        client.postMessage({
          type: 'SW_UPDATED',
          version: SW_VERSION
        });
      } catch (e) {}
    });
  })());
});

/* =========================================================
   PESAN DARI HALAMAN
   ========================================================= */

self.addEventListener('message', function (event) {
  var data = event.data || {};

  if (data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }

  if (
    data.type === 'GET_SW_VERSION' &&
    event.source
  ) {
    try {
      event.source.postMessage({
        type: 'SW_VERSION',
        version: SW_VERSION
      });
    } catch (e) {}
  }
});

/* =========================================================
   FETCH
   ========================================================= */

self.addEventListener('fetch', function (event) {
  var request = event.request;

  if (!request || request.method !== 'GET') {
    return;
  }

  var url;

  try {
    url = new URL(request.url);
  } catch (e) {
    return;
  }

  /*
   * HTML:
   * Selalu coba jaringan terlebih dahulu dengan HTTP cache
   * dilewati. Cache shell hanya dipakai jika jaringan gagal.
   */
  if (
    url.origin === self.location.origin &&
    request.mode === 'navigate'
  ) {
    event.respondWith((async function () {
      var cache = await caches.open(SHELL_CACHE);

      try {
        var response = await fetch(
          makeNoStoreRequest(request)
        );

        if (
          response &&
          response.ok &&
          response.type !== 'opaque'
        ) {
          try {
            // Simpan berdasarkan URL navigasi yang diminta.
            await cache.put(
              request,
              response.clone()
            );

            // Perbarui fallback canonical shell.
            if (request.url !== APP_SHELL_URL) {
              await cache.put(
                APP_SHELL_URL,
                response.clone()
              );
            }
          } catch (e) {}
        }

        // Jika server merespons HTTP error, jangan menyamarkannya
        // dengan HTML lama dari cache.
        return response;
      } catch (networkError) {
        var cached = await cache.match(request);

        if (cached) {
          return cached;
        }

        cached = await cache.match(APP_SHELL_URL);

        if (cached) {
          return cached;
        }

        return new Response(
          '<!doctype html>' +
          '<html lang="id">' +
          '<meta charset="utf-8">' +
          '<meta name="viewport" content="width=device-width,initial-scale=1">' +
          '<title>ReHolz HRIS offline</title>' +
          '<body style="font-family:system-ui;padding:2rem">' +
          '<h2>ReHolz HRIS sedang offline</h2>' +
          '<p>Versi halaman belum tersimpan di cache perangkat. ' +
          'Sambungkan internet lalu muat ulang halaman.</p>' +
          '</body></html>',
          {
            status: 503,
            headers: {
              'Content-Type': 'text/html; charset=utf-8',
              'Cache-Control': 'no-store'
            }
          }
        );
      }
    })());

    return;
  }

  /*
   * Cache-first hanya untuk pustaka CDN versi tetap:
   * Face API 1.7.12 dan Leaflet 1.9.4.
   * API, data backend, foto, dan tile peta tidak masuk cache.
   */
  if (!isPinnedImmutableCdn(url)) {
    return;
  }

  event.respondWith((async function () {
    var cache = await caches.open(CDN_CACHE);
    var cached = await cache.match(request);

    if (cached) {
      return cached;
    }

    try {
      var response = await fetch(request);

      /*
       * Respons opaque dapat diterima untuk script cross-origin
       * klasik tanpa CORS, tetapi hanya karena URL masuk daftar
       * pustaka versi tetap di atas.
       */
      if (
        response &&
        (
          response.type === 'opaque' ||
          (
            response.ok &&
            (
              response.type === 'cors' ||
              response.type === 'basic'
            )
          )
        )
      ) {
        try {
          await cache.put(
            request,
            response.clone()
          );

          await trimCdnCache(cache);
        } catch (e) {}
      }

      return response;
    } catch (networkError) {
      // Jika belum ada cache CDN, biarkan loader alternatif
      // di halaman mencoba sumber pustaka lainnya.
      throw networkError;
    }
  })());
});
