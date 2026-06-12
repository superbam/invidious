'use strict';

// AirPlay support (fork feature). Adds an AirPlay button to the video.js control
// bar on Safari/WebKit, where the Remote Playback picker is available. It is a
// no-op in every other browser. Loaded after player.js, which defines the global
// `player`, so we only hook into the existing player rather than touching it.
//
// Video over AirPlay: Safari only lists an Apple TV as a *video* destination when
// the <video> element has a native video track. The default Invidious quality is
// DASH, which video.js plays through MSE — Safari sees no routable video, so the
// picker lists audio devices only ("audio works, video isn't an option").
//
// To keep full quality during normal viewing, the switch is *deliberate*: tapping
// the AirPlay button switches to a progressive (native) MP4 and then opens the
// picker in the same gesture, so the element is routable as video when you cast.
// Full DASH quality is restored when casting ends or the target leaves. Progressive
// maxes out at ~720p (the muxed limit), which is the cap on AirPlay video here.
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

        // Captured before any quality switch (a switch replaces the source list).
        var progressiveSources = nativeVideoSources();

        // Track a temporary downgrade so we can restore full quality afterwards.
        var originalSource = null;
        var downgraded = false;

        // Replace the active source, preserving playback position and play state.
        function switchSource(source) {
            if (!source) return;
            var resumeAt = player.currentTime();
            var wasPlaying = !player.paused();

            player.src(source);
            player.one('loadedmetadata', function () {
                if (resumeAt) player.currentTime(resumeAt);
                if (wasPlaying) {
                    var playback = player.play();
                    if (playback && typeof playback.catch === 'function') playback.catch(function () {});
                }
            });
        }

        // Ensure the element has a native video source so the Apple TV is offered
        // as a *video* AirPlay target. No-op unless we're on DASH and a muxed
        // source exists (e.g. skipped for live HLS and audio-only/listen mode).
        function ensureNativeSource() {
            if (downgraded || player.currentType() !== DASH_TYPE || !progressiveSources.length) return;
            originalSource = player.currentSource();
            downgraded = true;
            switchSource(progressiveSources[0]);
        }

        // Restore the original (DASH) source once it's safe — not while casting.
        function restoreOriginalSource() {
            if (!downgraded || videoEl.webkitCurrentPlaybackTargetIsWireless) return;
            downgraded = false;
            var source = originalSource;
            originalSource = null;
            switchSource(source);
        }

        var Button = videojs.getComponent('Button');
        var airplayButton = new Button(player, {
            clickHandler: function () {
                // Deliberate switch: make the element video-routable, then open the
                // picker within this same gesture (Safari requires the gesture, and
                // fixes the device list when the picker opens).
                ensureNativeSource();
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

        videoEl.addEventListener('webkitplaybacktargetavailabilitychanged', function (event) {
            if (event.availability === 'available') {
                // Just surface the button — no source change until the user taps it,
                // so normal viewing keeps full DASH quality.
                airplayButton.show();
            } else {
                airplayButton.hide();
                restoreOriginalSource();
            }
        });

        videoEl.addEventListener('webkitcurrentplaybacktargetiswirelesschanged', function () {
            var isWireless = videoEl.webkitCurrentPlaybackTargetIsWireless;
            airplayButton.toggleClass('vjs-airplay-active', isWireless);
            // Casting ended: go back to full-quality DASH.
            if (!isWireless) restoreOriginalSource();
        });
    });
})();
