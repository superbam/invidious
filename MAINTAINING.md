# Maintaining this fork

This is a long-lived fork of [iv-org/invidious](https://github.com/iv-org/invidious).
It is **not** intended to be merged upstream — instead it tracks upstream for bug
and extraction fixes while carrying local features on top. This document is the
playbook for absorbing upstream changes without breaking those features.

## Fork model

| Branch | Role |
| --- | --- |
| `master` | Clean mirror of `upstream/master`. Never commit features here. |
| `shorts-filter` | `master` + all local features. This is the branch you deploy. |

Remotes (already configured):

```
origin    https://github.com/superbam/invidious.git
upstream  https://github.com/iv-org/invidious.git
```

## Local features (what we add on top of upstream)

- **Shorts filtering** — detect YouTube Shorts and let users hide/show them.
- **SponsorBlock + DeArrow proxy API** — `src/invidious/routes/api/v1/sponsorblock.cr` (new file): `/api/v1/sponsorblock/timings/:id`, `/api/v1/dearrow/branding/:id`, `/api/v1/dearrow/thumbnail/:id`.
- **PWA** — installable progressive web app. New files: `assets/sw.js` (service worker: cache-first versioned assets, network-only streams/proxy/auth, network-first navigations with offline fallback), `assets/js/sw-register.js` (registration), `assets/offline.html` (offline fallback). Marked edits: iOS standalone `<meta>` tags + the registration `<script>` in `template.ecr`; `worker-src 'self'` in the CSP in `routes/before_all.cr`.
- **Offline downloads** — save a muxed video or audio-only file for offline playback, with SponsorBlock segments captured at download time and a resume position; finishing offline queues a mark-watched that syncs via `/watch_ajax` when next online on a logged-in page (no DB/server changes). New files: `assets/js/offline.js` (IndexedDB store + downloader + sync queue, `window.InvidiousOffline`), `assets/js/download_button.js` (watch-page widget), `assets/js/offline_library.js` + `assets/downloads.html` (standalone, SW-precached library/player), `assets/css/offline.css`. Marked edits: download widget block in `watch.ecr`; a "Downloads" footer link in `template.ecr`. `/sw.js` precaches the library + its assets.
- **Thumbnail/UI tweaks** — rounded corners, hi-DPI `srcset`, watched indicators.

For consumers building external clients (e.g. the Apple TV / iOS app), see `docs/API_CLIENT_GUIDE.md`.

## The golden rule: keep edits to upstream files thin and marked

Every independent edit-block in an upstream file is a separate future merge
conflict. Two habits keep that surface small:

1. **Put logic in our own files.** New files never conflict. Shorts detection
   lives in `src/invidious/yt_backend/shorts.cr` (`Invidious::Shorts`); the
   Shorts backfill route lives in `src/invidious/routes/feeds_shorts.cr`. Upstream
   files call into these with a single line.

2. **Wrap unavoidable inline edits in markers** so a conflict is trivial to spot
   and re-apply:

   ```crystal
   # >>> shorts-filter
   ...our code...
   # <<< shorts-filter
   ```

   For single-line edits, a trailing `# shorts-filter` comment is enough. Where
   we replaced upstream code, the marker notes what upstream had, e.g.
   `# >>> shorts-filter (upstream: base_url = "/feed/subscriptions" ...)`.

   Find every local edit at a glance:

   ```sh
   git grep -n "shorts-filter"
   ```

## Updating from upstream

```sh
# 1. Fast-forward the mirror.
git checkout master
git fetch upstream
git merge --ff-only upstream/master
git push origin master

# 2. Merge the mirror into the feature branch.
git checkout shorts-filter
git merge master

# 3. If there are conflicts, they'll be inside `# >>> shorts-filter` markers.
#    Re-apply our line(s), keep upstream's surrounding code, then:
#       git add -p && git commit

# 4. Verify before pushing (see below), then:
git push origin shorts-filter
```

Merge **small and often**. A two-commit gap merges cleanly; a release-sized gap
is where the painful conflicts live.

### High-churn files to watch

These upstream files change most often and carry our edits, so they're the most
likely to conflict (counts = upstream commits touching them in a recent 200-commit
window):

| churn | file | what we changed |
| --- | --- | --- |
| 94 | `views/components/item.ecr` | thumbnail `srcset`, watched indicator |
| 65 | `yt_backend/extractors.cr` | 1-line call to `Invidious::Shorts` + 2 badge lines |
| 58 | `config.cr` | `filter_shorts` config |
| 52 | `routes/watch.cr` | watch-page tweaks |
| 48 | `routes/feeds.cr` | view filter + webhook Short detection |
| — | `views/template.ecr` | iOS PWA `<meta>` tags, SW registration script, Downloads footer link; navbar reorg (Log out removed, gear enlarged + pinned right) |
| — | `views/watch.ecr` | offline-download widget block (container + offline.css/js) |
| — | `views/components/feed_menu.ecr` | Watch history link added to top feed row |
| — | `views/feeds/subscriptions.ecr` | compact centered Videos/Shorts/All filter + RSS; removed Manage subs / Watch history (moved elsewhere) |
| — | `views/user/preferences.ecr` | Log out form added (moved from navbar) |
| — | `routes/before_all.cr` | `worker-src 'self'` in the CSP |

`extractors.cr` keeps upstream's length-parsing block **byte-for-byte**; our only
addition is a marked call to `Invidious::Shorts.detect_in_renderer`. Keep it that
way — don't re-inline detection logic into that block.

## Verifying after a merge

```sh
crystal spec        # runs the Shorts smoke test among others
crystal build --warnings all --error-on-warnings src/invidious.cr
crystal tool format --check
```

CI (`.github/workflows/ci.yml`) runs all three on push. Crystal isn't required
locally — you can rely on CI as the gate, but a local `crystal spec` is faster.

### Smoke test (semantic safety net)

`spec/invidious/yt_backend/shorts_spec.cr` feeds minimal InnerTube fixtures into
`Invidious::Shorts.detect_in_renderer`, one per detection signal. A clean merge
that silently breaks Short detection (the failure mode `git` can't see) turns this
red. If you add or change a detection signal, add a fixture here.

### Merge canary (early warning)

`.github/workflows/merge-canary.yml` runs weekly, dry-run-merges `upstream/master`
into `shorts-filter`, and opens a `merge-canary`-labelled issue if it no longer
merges cleanly — so you hear about drift on your schedule, not at deploy time.

> **GitHub limitation:** scheduled workflows only run from the repository's
> **default branch**. For the weekly cron to fire, set `shorts-filter` as this
> fork's default branch (Settings → Branches). You can always trigger it manually
> via the Actions tab → "Run workflow".

## Database note

Shorts filtering needs the `is_short` column on `channel_videos`
(migration `0011_add_is_short_to_channel_videos.cr`). If filtering silently does
nothing, the column is probably missing — Invidious only creates it when
`check_tables` is enabled or you run with `--migrate`. After deploying, run the
backfill once to flag existing rows:

```
GET /feed/subscriptions/backfill_shorts        # admin-only when admins are configured
```
