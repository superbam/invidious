'use strict';

// Service-worker registration (fork feature). Kept in its own file because the
// page CSP is `script-src 'self'` — an inline <script> would be blocked.
//
// We register /sw.js with the SAME ?v=<ASSET_COMMIT> this file was loaded with, so
// every deploy points at a fresh worker URL (which rotates the worker's caches).
(function () {
    if (!('serviceWorker' in navigator)) return;

    // Recover the ?v=<commit> from our own <script src> so sw.js is versioned too.
    var version = '';
    try {
        var self_script = document.currentScript;
        if (self_script && self_script.src) {
            version = new URL(self_script.src).search; // e.g. "?v=abc1234"
        }
    } catch (e) { /* fall back to an unversioned worker URL */ }

    window.addEventListener('load', function () {
        navigator.serviceWorker.register('/sw.js' + version).catch(function (err) {
            console.warn('Service worker registration failed:', err);
        });
    });
})();
