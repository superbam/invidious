'use strict';
// DeArrow — apply crowd-sourced titles/thumbnails to video cards on feed-style
// pages (subscriptions, trending, popular, channel, search, playlists), which
// all render through components/item.ecr. Mirrors the watch-page logic in
// watch.js, but fetches per-card instead of for a single video.

(function () {
    var prefs_el = document.getElementById('dearrow_feed_data');
    if (!prefs_el) return;

    var prefs = JSON.parse(prefs_el.textContent);
    if (!prefs.dearrow_titles && !prefs.dearrow_thumbnails) return;

    var ids = [];
    var seen = {};

    function collect(el) {
        var id = el.getAttribute('data-video-id');
        if (id && !seen[id]) {
            seen[id] = true;
            ids.push(id);
        }
    }

    document.querySelectorAll('img.thumbnail[data-video-id]').forEach(collect);
    document.querySelectorAll('a.dearrow-title[data-video-id]').forEach(collect);

    ids.forEach(function (id) {
        helpers.xhr('GET', '/api/v1/dearrow/branding/' + id, {
            responseType: 'json',
            timeout: 8000,
            entity_name: 'dearrow-feed',
        }, {
            on200: function (data) {
                if (prefs.dearrow_titles) {
                    var best = (data.titles || []).find(function (t) {
                        return !t.original && t.votes >= 0;
                    });
                    if (best) {
                        var clean = best.title.split(' ').map(function (w) {
                            return w.startsWith('>') ? w.slice(1) : w;
                        }).join(' ').trim();

                        if (clean) {
                            document.querySelectorAll('a.dearrow-title[data-video-id="' + id + '"] p').forEach(function (p) {
                                p.textContent = clean;
                            });
                        }
                    }
                }

                if (prefs.dearrow_thumbnails) {
                    var best_thumb = (data.thumbnails || []).find(function (t) {
                        return !t.original && t.votes >= 0 && t.timestamp != null;
                    });
                    if (best_thumb) {
                        var thumb_url = '/api/v1/dearrow/thumbnail/' + id + '?time=' + best_thumb.timestamp;

                        document.querySelectorAll('img.thumbnail[data-video-id="' + id + '"]').forEach(function (img) {
                            // Preload so a not-yet-generated thumbnail (which
                            // fails) never clobbers the working default.
                            var preload = new Image();
                            preload.onload = function () {
                                img.removeAttribute('srcset');
                                img.removeAttribute('sizes');
                                img.src = thumb_url;
                            };
                            preload.src = thumb_url;
                        });
                    }
                }
            },
        });
    });
})();
