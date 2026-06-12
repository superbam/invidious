'use strict';

// Watch-page "save for offline" widget (fork feature). Renders into the
// #offline-download container (added in watch.ecr) and drives window.InvidiousOffline
// to store the video/audio for offline playback. Also flushes any queued
// mark-watched actions while we're here with a valid CSRF token.
(function () {
    var container = document.getElementById('offline-download');
    if (!container || !window.InvidiousOffline) return;
    if (!('indexedDB' in window)) return;

    var data = {};
    try {
        data = JSON.parse(document.getElementById('video_data').textContent);
    } catch (e) { return; }

    var id = data.id;
    if (!id) return;

    var categories = Array.isArray(data.sponsorblock_categories)
        ? data.sponsorblock_categories.join(',')
        : 'sponsor';

    // Opportunistically push offline-completed watches up to the server.
    function flush() {
        if (data.mark_watched_enabled && data.csrf_token) {
            InvidiousOffline.flushSync(data.csrf_token);
        }
    }
    flush();
    window.addEventListener('online', flush);

    function el(tag, attrs, text) {
        var node = document.createElement(tag);
        if (attrs) Object.keys(attrs).forEach(function (k) { node.setAttribute(k, attrs[k]); });
        if (text != null) node.textContent = text;
        return node;
    }

    function clear() { while (container.firstChild) container.removeChild(container.firstChild); }

    function renderSaved(meta) {
        clear();
        var box = el('div', {'class': 'offline-saved'});
        box.appendChild(el('span', {'class': 'offline-badge'}, '✓ Saved offline'));
        var detail = (meta.kind === 'audio' ? 'Audio' : 'Video') +
            (meta.qualityLabel ? ' · ' + meta.qualityLabel : '');
        box.appendChild(el('span', {'class': 'offline-detail'}, detail));

        var play = el('a', {'class': 'pure-button', 'href': '/downloads.html#' + encodeURIComponent(id)}, 'Play offline');
        box.appendChild(play);

        var remove = el('button', {'class': 'pure-button', 'type': 'button'}, 'Remove');
        remove.addEventListener('click', function () {
            remove.disabled = true;
            InvidiousOffline.deleteVideo(id).then(renderIdle);
        });
        box.appendChild(remove);
        container.appendChild(box);
    }

    function renderProgress() {
        clear();
        var box = el('div', {'class': 'offline-progress'});
        var label = el('span', {'class': 'offline-status'}, 'Preparing…');
        var bar = el('div', {'class': 'offline-bar'});
        var fill = el('div', {'class': 'offline-bar-fill'});
        bar.appendChild(fill);
        box.appendChild(label);
        box.appendChild(bar);
        container.appendChild(box);
        return {
            update: function (ratio, stage) {
                var pct = Math.round((ratio || 0) * 100);
                fill.style.width = pct + '%';
                if (stage === 'media') label.textContent = 'Downloading… ' + pct + '%';
                else if (stage === 'thumb') label.textContent = 'Finishing…';
                else if (stage === 'info') label.textContent = 'Preparing…';
            },
            fail: function (msg) {
                label.textContent = msg || 'Download failed.';
                box.appendChild(el('div', {'class': 'offline-error'}, ''));
            }
        };
    }

    function renderIdle() {
        clear();
        var box = el('div', {'class': 'offline-idle'});
        box.appendChild(el('label', {'for': 'offline-kind', 'class': 'offline-label'}, 'Save for offline:'));

        var select = el('select', {'id': 'offline-kind', 'class': 'offline-select'});
        select.appendChild(el('option', {'value': 'video'}, 'Video (best muxed)'));
        select.appendChild(el('option', {'value': 'audio'}, 'Audio only'));
        box.appendChild(select);

        var save = el('button', {'class': 'pure-button pure-button-primary', 'type': 'button'}, 'Download');
        save.addEventListener('click', function () {
            var kind = select.value;
            var ui = renderProgress();
            InvidiousOffline.download(id, kind, {
                categories: categories,
                onProgress: ui.update
            }).then(function (meta) {
                renderSaved(meta);
            }).catch(function (err) {
                ui.fail((err && err.message) || 'Download failed.');
                // Offer a retry after a failure.
                var retry = el('button', {'class': 'pure-button', 'type': 'button'}, 'Try again');
                retry.addEventListener('click', renderIdle);
                container.appendChild(retry);
            });
        });
        box.appendChild(save);
        container.appendChild(box);
    }

    InvidiousOffline.getMeta(id).then(function (meta) {
        if (meta) renderSaved(meta); else renderIdle();
    }).catch(renderIdle);
})();
