'use strict';

// Service worker (fork feature) — makes Invidious an installable PWA and gives it
// an offline fallback. Registered by /js/sw-register.js with a `?v=<ASSET_COMMIT>`
// query, so a new deploy ships a new worker URL and the version-stamped caches
// below roll over automatically.
//
// Caching policy is deliberately conservative for a YouTube front-end:
//   - Static, content-addressed assets (/css, /js, /fonts, icons — all served
//     with ?v=<commit>) are cache-first: safe because the URL changes per deploy.
//   - Video/stream/proxy/auth-sensitive paths are never touched (network-only):
//     they are huge, IP-locked, expiring, or personalized.
//   - Page navigations are network-first, falling back to /offline.html so an
//     offline launch shows something instead of the browser error page.
//
// NOTE: this worker does NOT cache video. Offline *playback* of saved videos is a
// separate, opt-in feature (see /js/download.js) that stores blobs in IndexedDB.

// The registration URL carries ?v=<ASSET_COMMIT>; reuse it to namespace caches so
// each deploy gets a clean cache and old ones are purged on activate.
var VERSION = new URLSearchParams(self.location.search).get('v') || 'dev';
var STATIC_CACHE = 'iv-static-' + VERSION;
var OFFLINE_URL = '/offline.html';

// Precached so the offline library + offline launch work with no network on the
// very first run. These use unversioned URLs (the cache rotates per deploy via the
// version-stamped cache name), matching how /downloads.html references its assets.
var PRECACHE = [
    OFFLINE_URL,
    '/downloads.html',
    '/js/offline.js',
    '/js/offline_library.js',
    '/css/offline.css'
];

// Paths we must never cache or intercept — let them hit the network untouched.
// Mirrors the proxy/stream/auth prefixes Invidious uses (see before_all.cr).
// NB: no '/download' here on purpose — it would also match our '/downloads.html'
// library page (which must be cacheable for offline). The server's /download
// endpoint is POST-only, and the worker already ignores non-GET requests.
var BYPASS_PREFIXES = [
    '/videoplayback', '/latest_version', '/api/manifest/', '/api/v1/',
    '/vi/', '/sb/', '/s_p/', '/yts/', '/ggpht/', '/companion/',
    '/login', '/logout', '/signout', '/authorize_token', '/token_ajax',
    '/subscription_ajax', '/playlist_ajax', '/watch_ajax'
];

var STATIC_PREFIXES = ['/css/', '/js/', '/fonts/'];
var STATIC_EXT = /\.(?:css|js|woff2?|ttf|eot|png|jpe?g|gif|svg|ico|webmanifest|xml)$/i;

function isStatic(url) {
    for (var i = 0; i < STATIC_PREFIXES.length; i++) {
        if (url.pathname.indexOf(STATIC_PREFIXES[i]) === 0) return true;
    }
    return STATIC_EXT.test(url.pathname);
}

function isBypassed(url) {
    for (var i = 0; i < BYPASS_PREFIXES.length; i++) {
        if (url.pathname.indexOf(BYPASS_PREFIXES[i]) === 0) return true;
    }
    return false;
}

// Cache-first: serve from cache, else fetch and store. Used for versioned assets,
// so a stale entry is impossible (the URL changes when the content does).
function cacheFirst(request) {
    return caches.match(request).then(function (cached) {
        if (cached) return cached;
        return fetch(request).then(function (response) {
            if (response && response.ok && response.type === 'basic') {
                var copy = response.clone();
                caches.open(STATIC_CACHE).then(function (cache) {
                    cache.put(request, copy);
                });
            }
            return response;
        });
    });
}

// Network-first for navigations; on failure (offline) show the offline page.
function networkFirst(request) {
    return fetch(request).catch(function () {
        return caches.match(request).then(function (cached) {
            return cached || caches.match(OFFLINE_URL);
        });
    });
}

self.addEventListener('install', function (event) {
    event.waitUntil(
        caches.open(STATIC_CACHE).then(function (cache) {
            // Don't let one missing asset abort the whole install.
            return Promise.all(PRECACHE.map(function (url) {
                return cache.add(url).catch(function () {});
            }));
        }).then(function () {
            return self.skipWaiting();
        })
    );
});

self.addEventListener('activate', function (event) {
    event.waitUntil(
        caches.keys().then(function (keys) {
            return Promise.all(keys.map(function (key) {
                // Drop caches from older deploys (anything not the current version).
                if (key.indexOf('iv-static-') === 0 && key !== STATIC_CACHE) {
                    return caches.delete(key);
                }
            }));
        }).then(function () {
            return self.clients.claim();
        })
    );
});

self.addEventListener('fetch', function (event) {
    var request = event.request;
    if (request.method !== 'GET') return;

    // Never intercept media or byte-range requests. Safari can break <video>
    // playback if a service worker proxies these (even pass-through), so we let
    // the browser handle them natively. (Belt-and-suspenders: media paths are
    // also covered by isBypassed below.)
    if (request.headers.has('range')) return;
    var dest = request.destination;
    if (dest === 'video' || dest === 'audio' || dest === 'track') return;

    var url;
    try {
        url = new URL(request.url);
    } catch (e) {
        return;
    }

    // Only manage our own origin; cross-origin (e.g. googlevideo) passes through.
    if (url.origin !== self.location.origin) return;
    if (isBypassed(url)) return;

    if (isStatic(url)) {
        event.respondWith(cacheFirst(request));
        return;
    }

    if (request.mode === 'navigate') {
        event.respondWith(networkFirst(request));
        return;
    }

    // Everything else (APIs, misc): let the browser handle it natively rather
    // than proxying unknown requests, which keeps the SW well clear of playback.
});
