'use strict';

// Offline downloads core (fork feature). Exposes window.InvidiousOffline — a small
// IndexedDB-backed store + downloader shared by the watch-page download button
// (/js/download_button.js) and the downloads library (/js/offline_library.js).
//
// What it stores, per saved video:
//   - a single progressive MUXED MP4 (video) or an audio-only file — both play
//     natively offline; muxed also AirPlays. (DASH is intentionally not supported
//     offline: it would mean hand-feeding MSE dozens of segments.)
//   - a thumbnail, any caption tracks, and the SponsorBlock skip segments captured
//     at download time, so offline playback can still skip sponsors.
//
// "Sync watched status" is handled with a tiny queue: finishing a video offline
// enqueues a mark-watched action that gets flushed to /watch_ajax (using a page's
// CSRF token) the next time you're online on a logged-in page. No server changes.
(function () {
    var DB_NAME = 'invidious_offline';
    var DB_VERSION = 1;

    // Light, listable metadata (incl. the small thumbnail) lives in `meta`; the
    // large media + caption blobs live in `media`, so listing the library never
    // has to pull video blobs into memory.
    var STORE_META = 'meta';
    var STORE_MEDIA = 'media';
    var STORE_SYNC = 'sync';

    var dbPromise = null;

    function openDB() {
        if (dbPromise) return dbPromise;
        dbPromise = new Promise(function (resolve, reject) {
            var req = indexedDB.open(DB_NAME, DB_VERSION);
            req.onupgradeneeded = function () {
                var db = req.result;
                if (!db.objectStoreNames.contains(STORE_META)) {
                    db.createObjectStore(STORE_META, {keyPath: 'id'});
                }
                if (!db.objectStoreNames.contains(STORE_MEDIA)) {
                    db.createObjectStore(STORE_MEDIA, {keyPath: 'id'});
                }
                if (!db.objectStoreNames.contains(STORE_SYNC)) {
                    db.createObjectStore(STORE_SYNC, {keyPath: 'key', autoIncrement: true});
                }
            };
            req.onsuccess = function () { resolve(req.result); };
            req.onerror = function () { reject(req.error); };
        });
        return dbPromise;
    }

    function tx(storeNames, mode, fn) {
        return openDB().then(function (db) {
            return new Promise(function (resolve, reject) {
                var transaction = db.transaction(storeNames, mode);
                var result;
                transaction.oncomplete = function () { resolve(result); };
                transaction.onerror = function () { reject(transaction.error); };
                transaction.onabort = function () { reject(transaction.error); };
                result = fn(transaction);
            });
        });
    }

    function reqToPromise(request) {
        return new Promise(function (resolve, reject) {
            request.onsuccess = function () { resolve(request.result); };
            request.onerror = function () { reject(request.error); };
        });
    }

    // --- Reads -------------------------------------------------------------

    function listVideos() {
        return openDB().then(function (db) {
            return reqToPromise(db.transaction(STORE_META, 'readonly')
                .objectStore(STORE_META).getAll());
        }).then(function (rows) {
            // Newest first.
            return rows.sort(function (a, b) { return (b.savedAt || 0) - (a.savedAt || 0); });
        });
    }

    function getMeta(id) {
        return openDB().then(function (db) {
            return reqToPromise(db.transaction(STORE_META, 'readonly')
                .objectStore(STORE_META).get(id));
        });
    }

    function getMedia(id) {
        return openDB().then(function (db) {
            return reqToPromise(db.transaction(STORE_MEDIA, 'readonly')
                .objectStore(STORE_MEDIA).get(id));
        });
    }

    function isSaved(id) {
        return getMeta(id).then(function (m) { return !!m; });
    }

    // --- Writes ------------------------------------------------------------

    function putMeta(meta) {
        return tx(STORE_META, 'readwrite', function (t) {
            t.objectStore(STORE_META).put(meta);
        });
    }

    function deleteVideo(id) {
        return tx([STORE_META, STORE_MEDIA], 'readwrite', function (t) {
            t.objectStore(STORE_META).delete(id);
            t.objectStore(STORE_MEDIA).delete(id);
        });
    }

    // Persist the resume position (best-effort; callers throttle this).
    function setResume(id, seconds) {
        return getMeta(id).then(function (meta) {
            if (!meta) return;
            meta.resumeAt = seconds;
            return putMeta(meta);
        });
    }

    // --- Sync queue (mark-watched) ----------------------------------------

    function enqueueWatched(id) {
        return getMeta(id).then(function (meta) {
            if (meta && !meta.watched) {
                meta.watched = true;
                putMeta(meta);
            }
            return tx(STORE_SYNC, 'readwrite', function (t) {
                t.objectStore(STORE_SYNC).put({action: 'mark_watched', id: id});
            });
        });
    }

    // Flush queued mark-watched actions to the server. Requires a CSRF token from
    // a logged-in, server-rendered page (the watch page provides it). No-op when
    // offline, when no token is available, or when the queue is empty.
    function flushSync(csrfToken) {
        if (!csrfToken || !navigator.onLine) return Promise.resolve();
        return openDB().then(function (db) {
            return reqToPromise(db.transaction(STORE_SYNC, 'readonly')
                .objectStore(STORE_SYNC).getAll());
        }).then(function (items) {
            if (!items || !items.length) return;
            var payload = 'csrf_token=' + csrfToken;
            return Promise.all(items.map(function (item) {
                if (item.action !== 'mark_watched') return Promise.resolve();
                return fetch('/watch_ajax?action=mark_watched&redirect=false&id=' +
                    encodeURIComponent(item.id), {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                    body: payload
                }).then(function (res) {
                    // Drop the queue entry only if the server accepted it.
                    if (res.ok) {
                        return tx(STORE_SYNC, 'readwrite', function (t) {
                            t.objectStore(STORE_SYNC).delete(item.key);
                        });
                    }
                }).catch(function () { /* keep it queued for next time */ });
            }));
        });
    }

    // --- Download ----------------------------------------------------------

    // Pull a URL into a Blob, reporting progress against Content-Length when known.
    function fetchBlob(url, onProgress) {
        return fetch(url, {credentials: 'same-origin'}).then(function (res) {
            if (!res.ok) throw new Error('HTTP ' + res.status + ' for ' + url);
            var total = parseInt(res.headers.get('Content-Length') || '0', 10);
            var type = res.headers.get('Content-Type') || '';
            if (!res.body || typeof res.body.getReader !== 'function') {
                return res.blob(); // no streaming: fall back to a plain blob
            }
            var reader = res.body.getReader();
            var chunks = [];
            var received = 0;
            return (function pump() {
                return reader.read().then(function (step) {
                    if (step.done) return new Blob(chunks, type ? {type: type} : undefined);
                    chunks.push(step.value);
                    received += step.value.length;
                    if (onProgress) onProgress(received, total);
                    return pump();
                });
            })();
        });
    }

    function pickFormat(info, kind) {
        if (kind === 'audio') {
            var audio = (info.adaptiveFormats || []).filter(function (f) {
                return (f.type || '').indexOf('audio/') === 0;
            });
            // Prefer m4a (broadest native support), then highest bitrate.
            audio.sort(function (a, b) {
                var am4a = (a.type || '').indexOf('audio/mp4') === 0 ? 1 : 0;
                var bm4a = (b.type || '').indexOf('audio/mp4') === 0 ? 1 : 0;
                if (am4a !== bm4a) return bm4a - am4a;
                return (parseInt(b.bitrate, 10) || 0) - (parseInt(a.bitrate, 10) || 0);
            });
            return audio[0];
        }
        // Video: progressive muxed streams only (formatStreams), highest first.
        var muxed = (info.formatStreams || []).slice().sort(function (a, b) {
            return (parseInt(b.qualityLabel, 10) || 0) - (parseInt(a.qualityLabel, 10) || 0);
        });
        return muxed[0];
    }

    // Download and store a video. kind is 'video' or 'audio'. Options:
    //   { categories: <SponsorBlock categories csv>, onProgress: fn(0..1, stage) }
    // Returns a Promise that resolves with the stored meta.
    function download(id, kind, options) {
        options = options || {};
        var onProgress = options.onProgress || function () {};
        var meta, mediaBlob, thumbBlob, captionTracks = [], segments = [];
        var videoInfo = null;

        // Ask the browser not to evict our downloads under storage pressure.
        // No-op / silently granted on most engines; harmless if unsupported.
        if (navigator.storage && navigator.storage.persist) {
            try { navigator.storage.persist(); } catch (e) {}
        }

        onProgress(0, 'info');
        return fetch('/api/v1/videos/' + encodeURIComponent(id), {credentials: 'same-origin'})
            .then(function (res) {
                if (!res.ok) throw new Error('Could not load video info (HTTP ' + res.status + ')');
                return res.json();
            })
            .then(function (info) {
                videoInfo = info;
                var fmt = pickFormat(info, kind);
                if (!fmt || !fmt.itag) {
                    throw new Error(kind === 'audio'
                        ? 'No audio-only stream is available for this video.'
                        : 'No downloadable muxed video stream is available (try audio-only).');
                }

                meta = {
                    id: id,
                    title: info.title || id,
                    author: info.author || '',
                    authorId: info.authorId || '',
                    lengthSeconds: info.lengthSeconds || 0,
                    kind: kind,
                    itag: fmt.itag,
                    mime: (fmt.type || '').split(';')[0],
                    qualityLabel: kind === 'audio'
                        ? (Math.round((parseInt(fmt.bitrate, 10) || 0) / 1000) + 'kbps')
                        : (fmt.qualityLabel || fmt.quality || ''),
                    savedAt: Date.now(),
                    resumeAt: 0,
                    watched: false
                };

                // Proxy the stream through this instance so it's same-origin and
                // doesn't depend on expiring googlevideo URLs at playback time.
                var mediaUrl = '/latest_version?id=' + encodeURIComponent(id) +
                    '&itag=' + encodeURIComponent(fmt.itag) + '&local=true';

                onProgress(0, 'media');
                return fetchBlob(mediaUrl, function (rec, tot) {
                    if (tot) onProgress(rec / tot, 'media');
                });
            })
            .then(function (blob) {
                mediaBlob = blob;
                meta.size = blob.size;
                // Thumbnail (small; proxied same-origin so it works offline).
                onProgress(1, 'thumb');
                return fetchBlob('/vi/' + encodeURIComponent(id) + '/mqdefault.jpg')
                    .catch(function () { return null; });
            })
            .then(function (blob) {
                thumbBlob = blob;
                if (thumbBlob) meta.thumb = thumbBlob;
                // SponsorBlock segments at download time.
                var cats = options.categories || 'sponsor';
                return fetch('/api/v1/sponsorblock/timings/' + encodeURIComponent(id) +
                    '?categories=' + encodeURIComponent(cats), {credentials: 'same-origin'})
                    .then(function (res) { return res.ok ? res.json() : []; })
                    .catch(function () { return []; });
            })
            .then(function (sb) {
                if (Array.isArray(sb)) {
                    segments = sb.filter(function (s) { return s.actionType === 'skip' && s.segment; })
                        .map(function (s) {
                            return {category: s.category, start: s.segment[0], end: s.segment[1]};
                        });
                }
                meta.segments = segments;
                // Captions (best-effort; skipped for audio-only). Reuse the video
                // info we already fetched above.
                if (kind === 'audio') return [];
                var caps = ((videoInfo && videoInfo.captions) || []).slice(0, 6); // cap to keep size sane
                return Promise.all(caps.map(function (c) {
                    var u = '/api/v1/captions/' + encodeURIComponent(id) +
                        '?label=' + encodeURIComponent(c.label);
                    return fetchBlob(u).then(function (b) {
                        return {label: c.label, language: c.language_code || '', blob: b};
                    }).catch(function () { return null; });
                }));
            })
            .then(function (caps) {
                captionTracks = (caps || []).filter(Boolean);
                meta.captionLabels = captionTracks.map(function (c) {
                    return {label: c.label, language: c.language};
                });
                // Store everything in one transaction.
                return tx([STORE_META, STORE_MEDIA], 'readwrite', function (t) {
                    t.objectStore(STORE_META).put(meta);
                    t.objectStore(STORE_MEDIA).put({
                        id: id, blob: mediaBlob, captions: captionTracks
                    });
                });
            })
            .then(function () {
                onProgress(1, 'done');
                return meta;
            });
    }

    // --- Storage estimate --------------------------------------------------

    function estimate() {
        if (navigator.storage && navigator.storage.estimate) {
            return navigator.storage.estimate();
        }
        return Promise.resolve({usage: 0, quota: 0});
    }

    window.InvidiousOffline = {
        listVideos: listVideos,
        getMeta: getMeta,
        getMedia: getMedia,
        isSaved: isSaved,
        download: download,
        deleteVideo: deleteVideo,
        setResume: setResume,
        enqueueWatched: enqueueWatched,
        flushSync: flushSync,
        estimate: estimate
    };
})();
