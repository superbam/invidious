'use strict';

// Offline library + player (fork feature) for /downloads.html. Lists everything
// saved by window.InvidiousOffline, plays it from IndexedDB, skips the stored
// SponsorBlock segments, remembers the resume position, and marks a video watched
// (queued for sync) when it finishes.
(function () {
    var list = document.getElementById('downloads-list');
    var empty = document.getElementById('downloads-empty');
    var usageEl = document.getElementById('downloads-usage');
    var playerWrap = document.getElementById('downloads-player');
    if (!list || !window.InvidiousOffline) return;

    var objectUrls = [];
    function trackUrl(blob, type) {
        var url = URL.createObjectURL(type ? new Blob([blob], {type: type}) : blob);
        objectUrls.push(url);
        return url;
    }
    function revokeAll() {
        objectUrls.forEach(function (u) { URL.revokeObjectURL(u); });
        objectUrls = [];
    }

    function el(tag, attrs, text) {
        var node = document.createElement(tag);
        if (attrs) Object.keys(attrs).forEach(function (k) { node.setAttribute(k, attrs[k]); });
        if (text != null) node.textContent = text;
        return node;
    }

    function fmtBytes(n) {
        if (!n) return '';
        var u = ['B', 'KB', 'MB', 'GB'];
        var i = 0;
        while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
        return n.toFixed(i ? 1 : 0) + ' ' + u[i];
    }

    function fmtDuration(s) {
        s = Math.floor(s || 0);
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
        function pad(x) { return (x < 10 ? '0' : '') + x; }
        return (h ? h + ':' + pad(m) : m) + ':' + pad(sec);
    }

    function renderUsage() {
        InvidiousOffline.estimate().then(function (est) {
            if (usageEl && est && est.usage) {
                usageEl.textContent = 'Using ' + fmtBytes(est.usage) +
                    (est.quota ? ' of ' + fmtBytes(est.quota) + ' available' : '');
            }
        });
    }

    function closePlayer() {
        if (!playerWrap) return;
        var v = playerWrap.querySelector('video');
        if (v) { try { v.pause(); } catch (e) {} v.removeAttribute('src'); v.load && v.load(); }
        while (playerWrap.firstChild) playerWrap.removeChild(playerWrap.firstChild);
        playerWrap.style.display = 'none';
        revokeAll();
    }

    function play(meta) {
        InvidiousOffline.getMedia(meta.id).then(function (media) {
            if (!media || !media.blob) return;
            revokeAll();

            var video = el('video', {'controls': '', 'playsinline': '', 'x-webkit-airplay': 'allow'});
            video.style.width = '100%';
            video.style.maxHeight = '80vh';
            video.style.background = '#000';
            video.src = trackUrl(media.blob);

            (media.captions || []).forEach(function (cap, i) {
                var track = el('track', {
                    'kind': 'captions',
                    'src': trackUrl(cap.blob, 'text/vtt'),
                    'label': cap.label || ('Track ' + (i + 1)),
                    'srclang': cap.language || 'en'
                });
                if (i === 0) track.setAttribute('default', '');
                video.appendChild(track);
            });

            // SponsorBlock skipping, sorted by start.
            var segments = (meta.segments || []).slice().sort(function (a, b) { return a.start - b.start; });

            video.addEventListener('loadedmetadata', function () {
                if (meta.resumeAt && meta.resumeAt < (video.duration - 2)) {
                    video.currentTime = meta.resumeAt;
                }
            });

            var lastSaved = 0, marked = false;
            video.addEventListener('timeupdate', function () {
                var t = video.currentTime;

                // Skip any segment we're currently inside.
                for (var i = 0; i < segments.length; i++) {
                    if (t >= segments[i].start && t < segments[i].end - 0.3) {
                        video.currentTime = segments[i].end;
                        break;
                    }
                }

                // Throttle resume-position writes to ~once every 5s.
                if (t - lastSaved > 5 || t < lastSaved) {
                    lastSaved = t;
                    InvidiousOffline.setResume(meta.id, t);
                }

                // Near the end → count as watched (enqueue mark-watched sync).
                if (!marked && video.duration && t >= video.duration * 0.92) {
                    marked = true;
                    InvidiousOffline.enqueueWatched(meta.id);
                }
            });

            video.addEventListener('ended', function () {
                InvidiousOffline.setResume(meta.id, 0);
                if (!marked) { marked = true; InvidiousOffline.enqueueWatched(meta.id); }
            });

            while (playerWrap.firstChild) playerWrap.removeChild(playerWrap.firstChild);
            var header = el('div', {'class': 'downloads-player-bar'});
            header.appendChild(el('span', {'class': 'downloads-player-title'}, meta.title));
            var close = el('button', {'class': 'pure-button', 'type': 'button'}, 'Close');
            close.addEventListener('click', closePlayer);
            header.appendChild(close);
            playerWrap.appendChild(header);
            playerWrap.appendChild(video);
            playerWrap.style.display = 'block';
            playerWrap.scrollIntoView({behavior: 'smooth', block: 'start'});

            var p = video.play();
            if (p && p.catch) p.catch(function () {});
        });
    }

    function card(meta) {
        var c = el('div', {'class': 'download-card'});

        var thumb = el('div', {'class': 'download-thumb'});
        if (meta.thumb) {
            thumb.appendChild(el('img', {'src': trackUrl(meta.thumb), 'alt': ''}));
        }
        if (meta.lengthSeconds) {
            thumb.appendChild(el('span', {'class': 'download-duration'}, fmtDuration(meta.lengthSeconds)));
        }
        if (meta.kind === 'audio') {
            thumb.appendChild(el('span', {'class': 'download-kind'}, '♪ Audio'));
        }
        thumb.addEventListener('click', function () { play(meta); });
        c.appendChild(thumb);

        var info = el('div', {'class': 'download-info'});
        var title = el('a', {'class': 'download-title', 'href': '#' + encodeURIComponent(meta.id)}, meta.title);
        title.addEventListener('click', function (e) { e.preventDefault(); play(meta); });
        info.appendChild(title);
        info.appendChild(el('div', {'class': 'download-author'}, meta.author || ''));

        var bits = [];
        if (meta.qualityLabel) bits.push(meta.qualityLabel);
        if (meta.size) bits.push(fmtBytes(meta.size));
        if (meta.segments && meta.segments.length) bits.push(meta.segments.length + ' SB segment' + (meta.segments.length > 1 ? 's' : ''));
        info.appendChild(el('div', {'class': 'download-meta'}, bits.join(' · ')));

        var actions = el('div', {'class': 'download-actions'});
        var playBtn = el('button', {'class': 'pure-button pure-button-primary', 'type': 'button'}, 'Play');
        playBtn.addEventListener('click', function () { play(meta); });
        actions.appendChild(playBtn);
        var del = el('button', {'class': 'pure-button', 'type': 'button'}, 'Delete');
        del.addEventListener('click', function () {
            del.disabled = true;
            InvidiousOffline.deleteVideo(meta.id).then(render);
        });
        actions.appendChild(del);
        info.appendChild(actions);

        c.appendChild(info);
        return c;
    }

    function render() {
        closePlayer();
        InvidiousOffline.listVideos().then(function (videos) {
            while (list.firstChild) list.removeChild(list.firstChild);
            if (!videos.length) {
                if (empty) empty.style.display = 'block';
                return;
            }
            if (empty) empty.style.display = 'none';
            videos.forEach(function (meta) { list.appendChild(card(meta)); });
            renderUsage();

            // Deep link: /downloads.html#<videoId> opens that video.
            var hash = decodeURIComponent((location.hash || '').replace(/^#/, ''));
            if (hash) {
                var match = videos.filter(function (v) { return v.id === hash; })[0];
                if (match) play(match);
            }
        });
    }

    render();
})();
