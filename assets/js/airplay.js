'use strict';

// AirPlay support (fork feature). Adds an AirPlay button to the video.js control
// bar on Safari/WebKit, where the Remote Playback picker is available. It is a
// no-op in every other browser. Loaded after player.js, which defines the global
// `player`, so we only hook into the existing player rather than touching it.
//
// Video over AirPlay: Safari can only AirPlay *video* when the <video> element
// plays a native source (a progressive muxed MP4, or native HLS). The default
// Invidious quality is DASH, which video.js plays through MSE — and Safari can
// only send the audio of an MSE stream. So when AirPlay activates on a DASH
// stream we switch to the best progressive MP4 (capped at ~720p, the muxed
// limit) so the full video reaches the TV. Live HLS already plays natively and
// is left alone.
(function () {
    // WebKitPlaybackTargetAvailabilityEvent only exists on Apple/WebKit builds
    // that expose AirPlay. Bail everywhere else so nothing changes.
    if (typeof window.WebKitPlaybackTargetAvailabilityEvent === 'undefined') return;
    if (typeof player === 'undefined' || !player) return;

    var DASH_TYPE = 'application/dash+xml';

    // Progressive muxed sources (type "video/mp4"), highest resolution first.
    // Excludes the DASH manifest (application/dash+xml) and audio-only streams.
    function nativeVideoSources() {
        return player.currentSources().filter(function (source) {
            return source.type && source.type.indexOf('video/') === 0;
        }).sort(function (a, b) {
            return (parseInt(b.label, 10) || 0) - (parseInt(a.label, 10) || 0);
        });
    }

    player.ready(function () {
        var videoEl = player.el().querySelector('video');
        if (!videoEl || typeof videoEl.webkitShowPlaybackTargetPicker !== 'function') return;

        // Captured before the user changes quality (a quality switch replaces the
        // source list). Falls back to a live lookup if empty when AirPlay starts.
        var progressiveSources = nativeVideoSources();

        var Button = videojs.getComponent('Button');
        var airplayButton = new Button(player, {
            clickHandler: function () {
                try {
                    videoEl.webkitShowPlaybackTargetPicker();
                } catch (err) {
                    console.warn('AirPlay: could not open the playback target picker', err);
                }
            }
        });

        airplayButton.controlText('AirPlay');
        airplayButton.addClass('vjs-airplay-button');
        // Hidden until the browser reports at least one available AirPlay target.
        airplayButton.hide();

        var controlBar = player.getChild('ControlBar');
        var fullscreen = controlBar.getChild('fullscreenToggle');
        // Sit just before the fullscreen toggle when present, else append.
        var position = fullscreen ? controlBar.children().indexOf(fullscreen) : undefined;
        controlBar.addChild(airplayButton, {}, position);

        // Swap to a native progressive source so the video (not just audio) can be
        // sent to the AirPlay target, preserving playback position and state.
        function switchToProgressive() {
            var sources = progressiveSources.length ? progressiveSources : nativeVideoSources();
            var best = sources[0];
            if (!best) return; // audio-only / no muxed stream: nothing we can do

            var resumeAt = player.currentTime();
            var wasPlaying = !player.paused();

            player.src(best);
            player.one('loadedmetadata', function () {
                if (resumeAt) player.currentTime(resumeAt);
                if (wasPlaying) {
                    var playback = player.play();
                    if (playback && typeof playback.catch === 'function') playback.catch(function () {});
                }
            });
        }

        videoEl.addEventListener('webkitplaybacktargetavailabilitychanged', function (event) {
            if (event.availability === 'available') {
                airplayButton.show();
            } else {
                airplayButton.hide();
            }
        });

        videoEl.addEventListener('webkitcurrentplaybacktargetiswirelesschanged', function () {
            var isWireless = videoEl.webkitCurrentPlaybackTargetIsWireless;
            airplayButton.toggleClass('vjs-airplay-active', isWireless);

            // On a DASH/MSE stream Safari only sends audio — switch to progressive
            // so the picture follows. Native (mp4/HLS) sources are left untouched.
            if (isWireless && player.currentType() === DASH_TYPE) {
                switchToProgressive();
            }
        });
    });
})();
