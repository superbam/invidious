'use strict';
var save_player_pos_key = 'save_player_pos';

function get_all_video_times() {
    return helpers.storage.get(save_player_pos_key) || {};
}

var all_video_times = get_all_video_times();

document.querySelectorAll('.watched-indicator').forEach(function (indicator) {
    // shorts-filter: prefer the account-synced position (rendered server-side
    // from playback_positions) over this browser's localStorage, so positions
    // set on another device / native client draw without opening the video here.
    var server_seconds = parseInt(indicator.dataset.watchedSeconds, 10);
    var watched_part = !isNaN(server_seconds) ? server_seconds : all_video_times[indicator.dataset.id];
    var total = parseInt(indicator.dataset.length, 10);
    var is_watched = indicator.dataset.watched === '1';

    if (watched_part === undefined) {
        // No saved playback position for this video. Fully fill the bar for
        // videos already in the watch history; otherwise there is nothing to
        // show, so leave the indicator hidden.
        if (!is_watched) return;
        watched_part = total;
    }

    var percentage = Math.round((watched_part / total) * 100);

    if (percentage < 5) {
        percentage = 5;
    }
    if (percentage > 90) {
        percentage = 100;
    }

    indicator.style.width = percentage + '%';
    indicator.style.display = '';
});
