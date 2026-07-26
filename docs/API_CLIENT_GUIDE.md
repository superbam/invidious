# Invidious API — client guide (Apple TV / iOS)

A practical guide to building a native client (tvOS / iOS, AVPlayer-based) against
this Invidious fork. It covers the public API surface, the fork-specific endpoints
(SponsorBlock/DeArrow proxy, Shorts), and how to map streams onto `AVPlayer` with
AirPlay.

This documents the endpoints actually present in this fork. For the canonical
upstream reference see <https://docs.invidious.io/api/>.

---

## 1. Basics

- **Base URL** is your instance origin, e.g. `https://invidious.example`. Make this
  user-configurable in the client; never hard-code a public instance.
- All endpoints below live under `/api/v1/` and return `application/json` (UTF-8).
  Binary endpoints (thumbnails, DeArrow images) return image bytes.
- **No API key** is required for public (non-`/auth`) endpoints. CORS is enabled.
- **Errors**: non-2xx responses return `{"error": "<message>"}`. Always check the
  HTTP status.
- Handy query params on most endpoints: `?pretty=1` (pretty-print) and
  `?fields=videoId,title,formatStreams` (comma-separated field projection — use it
  to shrink responses on tvOS).

---

## 2. Authentication (only for personalized data)

Discovery and playback need **no auth**. You only need a token for `/api/v1/auth/*`
(a user's subscriptions, playlists, watch history, notifications).

**Token model** (see `src/invidious/helpers/handlers.cr`): authenticated requests
carry an `Authorization` header:

```
Authorization: Bearer <url-encoded-token-json>
```

The token is the URL-encoded JSON blob minted by the instance's
`/authorize_token` flow. Acquisition (OAuth-like redirect):

1. The user logs into the instance in a web view.
2. Send them to
   `https://invidious.example/authorize_token?scopes=:*&callback_url=<your-app-scheme>://auth`
   (narrow the `scopes` to least privilege in production, e.g.
   `GET:subscriptions,GET:playlists,GET:feed`).
3. The instance redirects back to your `callback_url` with the `token`.
4. Store it in the Keychain; send it as the `Bearer` value on `/auth` calls.

A session cookie (`SID`) also works if you prefer cookie auth, but the Bearer token
is the right fit for a native client. Tokens are scoped and expirable.

---

## 3. Discovery

| Endpoint | Purpose | Key params |
| --- | --- | --- |
| `GET /api/v1/search` | Search | `q`, `type` (`video`\|`channel`\|`playlist`\|`all`), `page`, `sort_by` (`relevance`\|`rating`\|`upload_date`\|`view_count`), `duration`, `date`, `features`, `region` |
| `GET /api/v1/search/suggestions` | Autocomplete | `q` |
| `GET /api/v1/trending` | Trending | `type` (`music`\|`gaming`\|`news`\|`movies`), `region` |
| `GET /api/v1/popular` | Popular on instance | — |
| `GET /api/v1/hashtag/:tag` | Hashtag feed | `page` |

Search results are a mixed array; switch on the `type` field of each item
(`"video"`, `"channel"`, `"playlist"`).

---

## 4. Video details & playback — the core

```
GET /api/v1/videos/:id
```

Notable fields (see `src/invidious/jsonify/api_v1/video_json.cr`):

| Field | Meaning |
| --- | --- |
| `videoId`, `title`, `author`, `authorId` | identity |
| `lengthSeconds` | duration (0 for live) |
| `liveNow`, `isUpcoming`, `isPostLiveDvr` | live state |
| `videoThumbnails[]` | `{quality, url, width, height}` |
| `hlsUrl` | **HLS master playlist — live streams only** |
| `dashUrl` | DASH MPD: `/api/manifest/dash/id/:id` |
| `formatStreams[]` | **progressive (muxed audio+video) MP4** |
| `adaptiveFormats[]` | separate video-only / audio-only tracks (DASH) |
| `captions[]` | `{label, language_code, url}` |
| `storyboards[]` | scrubbing-preview sprite sheets (WebVTT) |
| `recommendedVideos[]` | related videos |

### Stream shapes

- **`formatStreams[]`** — each has `url`, `itag`, `type` (MIME), `quality`,
  `qualityLabel` (e.g. `"720p"`), `resolution`, `size`, `bitrate`, `container`,
  `encoding`. These are **muxed** (audio+video in one file), capped at 720p (itag
  22) / 360p (itag 18). One URL → plays directly.
- **`adaptiveFormats[]`** — higher quality (up to 4K/8K) but **split**: video-only
  and audio-only entries. Fields add `init`, `index`, `fps`, `audioQuality`,
  `audioSampleRate`, `audioChannels`. You must combine these via the DASH manifest;
  `AVPlayer` cannot play a lone adaptive track usefully.

### Stream URL stability (important)

Raw `googlevideo.com` URLs **expire (~6h) and are IP-locked to the instance**. If
your client's IP differs from the server's, those URLs won't play. Two fixes:

- Append **`?local=true`** to a stream URL to proxy it through the instance
  (recommended for clients).
- Or use the stable proxied endpoint:
  `GET /latest_version?id=<videoId>&itag=<itag>&local=true` — resolves to a fresh
  stream each time, so it's safe to keep in a playlist.

### Mapping to `AVPlayer`

`AVPlayer` is **HLS-first**. Pick the source by case:

| Case | Use | Why |
| --- | --- | --- |
| **Live** | `hlsUrl` | Native HLS; AirPlay works perfectly |
| **VOD, simple** | a `formatStreams` entry (e.g. itag 22, 720p), via `?local=true` | One muxed URL `AVPlayer` plays directly; AirPlay works |
| **VOD, >720p** | `dashUrl` | `AVPlayer` won't play DASH natively — you need a DASH→HLS repackager or a third-party player. Simplest Apple-native path is HLS. |

> **AirPlay caveat (same as the web player):** muxed `formatStreams` and `hlsUrl`
> route to an Apple TV cleanly. DASH/adaptive does **not** stream as video over
> AirPlay — it tends to mirror only. For a v1 app, prefer 720p muxed for VOD and
> `hlsUrl` for live; add adaptive/DASH later behind a repackager.

```swift
// Minimal VOD playback (muxed) + AirPlay
import AVKit

let base = URL(string: "https://invidious.example")!
let video = try await fetchVideo(id: "dQw4w9WgXcQ")          // your Codable fetch
let muxed = video.formatStreams.first { $0.itag == "22" }    // 720p
            ?? video.formatStreams.first!
var comps = URLComponents(string: muxed.url.hasPrefix("http") ? muxed.url
                                  : base.absoluteString + muxed.url)!
comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "local", value: "true")]

let player = AVPlayer(url: comps.url!)
let vc = AVPlayerViewController()
vc.player = player                     // AVPlayerViewController shows the AirPlay route button automatically
try? AVAudioSession.sharedInstance().setCategory(.playback)   // required for AirPlay/background audio
player.play()
```

For a custom UI instead of `AVPlayerViewController`, add an `AVRoutePickerView`
for the AirPlay button. `player.allowsExternalPlayback` is `true` by default.

---

## 5. Captions / subtitles

`captions[]` gives `{label, language_code, url}` where `url` is
`/api/v1/captions/:id?label=<name>`. Returns **WebVTT**. Either:

- Hand the URL to `AVPlayer` as a side-loaded `AVMediaSelectionGroup` (requires an
  HLS master that references it), or
- Download the VTT and render captions yourself over the player.

For live/long videos there's also `GET /api/v1/transcripts/:id`.

---

## 6. Channels

| Endpoint | Returns |
| --- | --- |
| `GET /api/v1/channels/:ucid` | channel metadata + latest videos |
| `GET /api/v1/channels/:ucid/videos` | uploads (paginated) |
| `GET /api/v1/channels/:ucid/shorts` | **Shorts tab** (see §11) |
| `GET /api/v1/channels/:ucid/streams` | past/live streams |
| `GET /api/v1/channels/:ucid/playlists` | playlists |
| `GET /api/v1/channels/:ucid/community` | community posts |
| `GET /api/v1/channels/:ucid/search` | search within channel |

Paginate tabs with the `continuation` token returned in the response
(`?continuation=<token>`), not page numbers.

---

## 7. Playlists, mixes, comments

- `GET /api/v1/playlists/:plid?page=N` — playlist + its videos.
- `GET /api/v1/mixes/:rdid` — YouTube radio/mix.
- `GET /api/v1/comments/:id?sort_by=top|new&source=youtube&continuation=<token>` —
  threaded comments; follow `continuation` for more.

---

## 8. Scrubbing previews & misc

- `GET /api/v1/storyboards/:id` — WebVTT pointing at sprite-sheet thumbnails for
  the scrubber.
- `GET /api/v1/resolveurl?url=<youtube url>` — resolve any YouTube URL to the
  Invidious entity (video/channel/playlist). Useful for "open in app" / share
  extensions.
- `GET /api/v1/stats` — instance health, version, user count, `openRegistrations`.
  Use it to validate a user-entered instance and show status.

---

## 9. Fork-specific endpoints

These are added by this fork (`src/invidious/routes/api/v1/sponsorblock.cr`), proxied
server-side so the client never talks to SponsorBlock/DeArrow directly (privacy +
no extra CORS/keys):

### SponsorBlock — skip segments

```
GET /api/v1/sponsorblock/timings/:id?categories=sponsor,intro,outro,selfpromo,...
```

- Valid categories: `sponsor`, `selfpromo`, `interaction`, `intro`, `outro`,
  `preview`, `music_offtopic`, `filler`, `poi_highlight`, `exclusive_access`,
  `chapter`. Defaults to `sponsor`.
- Returns SponsorBlock's `skipSegments` JSON: an array of objects with
  `category` and `segment: [startSeconds, endSeconds]`. `404`/no segments → `[]`.
- **Client use**: observe `AVPlayer` time (`addPeriodicTimeObserver`) and `seek`
  past any segment whose range you enter; optionally show a "skip" button instead.

### DeArrow — crowd-sourced titles & thumbnails

```
GET /api/v1/dearrow/branding/:id            -> {"titles":[...], "thumbnails":[...]}
GET /api/v1/dearrow/thumbnail/:id?time=<s>  -> image/jpeg (a frame grab; cached 1h)
```

Use these to optionally replace clickbait titles/thumbnails in your UI.

### Shorts

This fork detects YouTube Shorts. Today the cleanest way to get Shorts in a client
is the channel Shorts tab:

```
GET /api/v1/channels/:ucid/shorts
```

> **Gap / enhancement:** individual video and search JSON does **not** currently
> expose an `isShort` flag (the flag lives in the DB and drives the web feed filter
> only). If your app wants to filter/badge Shorts inline, the clean change is to add
> `isShort` to `serialized_yt_data.cr` (search items) and `video_json.cr` (video
> detail). Ask and this can be added to the API.

### "Don't recommend" list

A per-user block list. Videos and channels on it are excluded from the
Discover feed (§10) and from `recommendedVideos` on video detail. Requires
the Bearer token from §2.

```
GET    /api/v1/auth/norecommend                  -> {"videos":[...], "channels":[...]}
DELETE /api/v1/auth/norecommend                  -> 204  (clear everything)
POST   /api/v1/auth/norecommend/videos/:id       -> 204  (block a video)
DELETE /api/v1/auth/norecommend/videos/:id       -> 204  (unblock)
POST   /api/v1/auth/norecommend/channels/:ucid   -> 204  (block a channel)
DELETE /api/v1/auth/norecommend/channels/:ucid   -> 204  (unblock)
```

- `GET` returns both sets as sorted string arrays — video ids and UCIDs.
  POST/DELETE are idempotent (blocking twice is not an error).
- Invalid ids are rejected with `400`: video ids must match
  `[a-zA-Z0-9_-]{11}`, channel ids `UC[a-zA-Z0-9_-]{22}`.

**Server-side filtering.** `GET /api/v1/videos/:id` is a public endpoint, but
it now honors a Bearer token *if you send one* — when it does, blocked entries
are stripped from `recommendedVideos` server-side. Sending no token (or an
expired one) still works and simply returns the unfiltered list; the endpoint
never 403s over auth. Note that a token makes the response user-specific, so
don't share a cache entry for it across accounts.

**Client-side filtering.** `GET /api/v1/auth/norecommend` is also there so you
can cache both sets locally and filter anything the server can't — search
results, channel tabs, a playlist — and to render your own "blocked" state in
the UI. Refresh the cache after any POST/DELETE.

**Suggested client use**: a context-menu / long-press action on a video card
("Don't recommend this video" / "…this channel") that POSTs, then removes the
card locally. Mirror the list in a settings screen so users can undo — the web
UI's equivalent lives at `/not_recommend_manager`.

### Instance health — "YouTube access degraded" flag

```
GET /api/v1/health -> {"youtubeAccessDegraded": false}
```

YouTube periodically changes something server-side (client-version strings,
response shapes) that breaks the extraction logic every Invidious fork relies
on, until the instance's admin updates it. This endpoint tracks recent
extraction failures (missing JSON fields, non-200s from YouTube's API, etc.)
in-process and flips `youtubeAccessDegraded` to `true` once several happen in
a short window — a much stronger signal than one flaky request. It resets
automatically every ~10 minutes.

- Always available, regardless of `CONFIG.statistics_enabled` — this is a
  health flag, not usage data.
- **Client use**: poll it occasionally (e.g. alongside your existing
  `/api/v1/stats` instance check, or after a couple of playback failures in a
  row) and show a local notification/banner like "This server is having
  trouble reaching YouTube — try again later or switch instances" when it's
  `true`, instead of silently failing one video at a time.
- The web UI's own equivalent is an admin-only banner (this flag has no
  concept of "admin" — any client polling it sees the same value).

---

## 10. Authenticated sync (`/api/v1/auth/*`, Bearer token)

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/api/v1/auth/feed` | GET | subscription feed |
| `/api/v1/auth/subscriptions` | GET | list subs |
| `/api/v1/auth/subscriptions/:ucid` | POST / DELETE | (un)subscribe |
| `/api/v1/auth/playlists` | GET / POST | list / create |
| `/api/v1/auth/playlists/:plid/videos` | POST | add video |
| `/api/v1/auth/playlists/:plid/videos/:index` | DELETE | remove video |
| `/api/v1/auth/history` | GET / DELETE | watch history |
| `/api/v1/auth/history/:id` | POST / DELETE | mark (un)watched |
| `/api/v1/auth/preferences` | GET / POST | user prefs |

All require the `Authorization: Bearer` token from §2 with a matching scope.

---

## 11. Swift quick-start (Codable)

```swift
struct InvVideo: Codable {
    let videoId: String
    let title: String
    let lengthSeconds: Int
    let liveNow: Bool
    let hlsUrl: String?
    let formatStreams: [Stream]
    let adaptiveFormats: [Stream]
    let captions: [Caption]

    struct Stream: Codable {
        let url: String
        let itag: String
        let type: String          // MIME
        let quality: String?
        let qualityLabel: String?
        let container: String?
        let bitrate: String?
    }
    struct Caption: Codable {
        let label: String
        let language_code: String
        let url: String
    }
}

func fetchVideo(id: String, base: URL) async throws -> InvVideo {
    let url = base.appendingPathComponent("api/v1/videos/\(id)")
    let (data, resp) = try await URLSession.shared.data(from: url)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    return try JSONDecoder().decode(InvVideo.self, from: data)
}
```

Design notes for tvOS/iOS:

- Make the **instance URL** a first-class setting; verify it via `/api/v1/stats`.
- Prefer **`?fields=`** projections to keep tvOS payloads small.
- Always proxy streams with **`?local=true`** so playback works regardless of the
  device's network/IP.
- Drive SponsorBlock skips from a single `addPeriodicTimeObserver`.
- For AirPlay reliability, default VOD to a muxed `formatStreams` entry and live to
  `hlsUrl`; treat DASH as an opt-in "high quality" mode.

---

## 12. Endpoint quick reference

```
Discovery   /api/v1/search  /search/suggestions  /trending  /popular  /hashtag/:tag
Video       /api/v1/videos/:id  /storyboards/:id  /captions/:id  /transcripts/:id  /comments/:id
Streams     /api/manifest/dash/id/:id   /api/manifest/hls_playlist/*   /latest_version?id=&itag=&local=true
Channels    /api/v1/channels/:ucid[/videos|/shorts|/streams|/playlists|/community|/search]
Playlists   /api/v1/playlists/:plid   /api/v1/mixes/:rdid
Fork        /api/v1/sponsorblock/timings/:id   /api/v1/dearrow/branding/:id   /api/v1/dearrow/thumbnail/:id   /api/v1/health
Fork (auth) /api/v1/auth/norecommend[/videos/:id|/channels/:ucid]   /api/v1/auth/discover
Auth        /api/v1/auth/{feed,subscriptions,playlists,history,preferences,...}   (Bearer token)
Misc        /api/v1/stats   /api/v1/resolveurl?url=
```
