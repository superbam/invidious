'use strict';

// AirPlay support (fork feature). Adds an AirPlay button to the video.js control
// bar on Safari/WebKit, where the Remote Playback picker is available. It is a
// no-op in every other browser. Loaded after player.js, which defines the global
// `player`, so we only hook into the existing player rather than touching it.
(function () {
    // WebKitPlaybackTargetAvailabilityEvent only exists on Apple/WebKit builds
    // that expose AirPlay. Bail everywhere else so nothing changes.
    if (typeof window.WebKitPlaybackTargetAvailabilityEvent === 'undefined') return;
    if (typeof player === 'undefined' || !player) return;

    player.ready(function () {
        var videoEl = player.el().querySelector('video');
        if (!videoEl || typeof videoEl.webkitShowPlaybackTargetPicker !== 'function') return;

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

        videoEl.addEventListener('webkitplaybacktargetavailabilitychanged', function (event) {
            if (event.availability === 'available') {
                airplayButton.show();
            } else {
                airplayButton.hide();
            }
        });

        videoEl.addEventListener('webkitcurrentplaybacktargetiswirelesschanged', function () {
            airplayButton.toggleClass('vjs-airplay-active', videoEl.webkitCurrentPlaybackTargetIsWireless);
        });
    });
})();
