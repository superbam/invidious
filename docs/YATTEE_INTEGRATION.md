# Yattee integration guide — fork-specific Invidious APIs

Two APIs added by this Invidious fork that a native client can use:

1. **`/api/v1/health`** — is this instance currently failing to reach YouTube?
2. **`/api/v1/auth/norecommend`** — a per-user "don't recommend" list for videos
   and channels.

Both are additions to stock Invidious. Everything else in the API is unchanged,
so this is purely additive — see `API_CLIENT_GUIDE.md` for the full surface.

---

## 0. Feature detection — read this first

Yattee talks to arbitrary Invidious instances, and **these endpoints only exist
on this fork**. A stock instance returns `404` for both. So don't assume
availability: probe once per instance, cache the answer, and hide the related UI
when it's absent.

```swift
/// Stock Invidious 404s here; this fork returns 200 with a JSON body.
func supportsForkAPIs(base: URL) async -> Bool {
    var req = URLRequest(url: base.appendingPathComponent("api/v1/health"))
    req.httpMethod = "GET"
    req.timeoutInterval = 5
    guard let (_, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse else { return false }
    return http.statusCode == 200
}
```

Re-probe when the user switches instances, not on every launch.

---

## 1. Instance health

```
GET /api/v1/health        (no auth)
-> 200 {"youtubeAccessDegraded": false}
```

YouTube periodically changes something server-side — client version strings,
response shapes — that breaks the extraction logic every Invidious fork depends
on, until the instance admin updates. When that happens, playback and metadata
requests start failing for reasons that have nothing to do with the user's
network or the specific video.

The instance counts recent extraction failures (missing JSON fields, YouTube
returning the wrong video, non-200s from YouTube's API) in-process. Several
inside one ~10-minute window flips `youtubeAccessDegraded` to `true`. It resets
automatically, so it reflects *now*, not history.

**Why bother:** it turns a confusing string of per-video failures into one clear
message. Suggested use — poll it when a couple of playback/metadata requests
fail in a row, and if it's `true` show something like:

> This server is having trouble reaching YouTube. This is usually temporary and
> affects everyone on the instance — try again shortly, or switch instances.

Don't poll it aggressively; on-failure plus an occasional background check
alongside your existing `/api/v1/stats` instance check is plenty. There's no
auth on it and no per-user variation — every caller sees the same flag.

---

## 2. The "don't recommend" list

A per-user block list. Entries are excluded from the instance's Discover feed
and from `recommendedVideos` on video detail.

All of these require the Bearer token described in `API_CLIENT_GUIDE.md` §2 —
the same one Yattee already uses for subscriptions/playlists/history.

```
GET    /api/v1/auth/norecommend                -> 200 {"videos":[...], "channels":[...]}
DELETE /api/v1/auth/norecommend                -> 204   clear everything
POST   /api/v1/auth/norecommend/videos/:id     -> 204   block a video
DELETE /api/v1/auth/norecommend/videos/:id     -> 204   unblock a video
POST   /api/v1/auth/norecommend/channels/:ucid -> 204   block a channel
DELETE /api/v1/auth/norecommend/channels/:ucid -> 204   unblock a channel
```

**Response shapes.** `GET` returns both sets as sorted arrays of plain strings —
video IDs and UCIDs:

```json
{
  "videos": ["dQw4w9WgXcQ", "jNQXAC9IVRw"],
  "channels": ["UCuAXFkgsw1L7xaCfnd5JJOw"]
}
```

Mutations return `204 No Content` with an empty body — don't try to decode one.

**Status codes.**

| Code | Meaning |
| --- | --- |
| `204` | Success (all POST/DELETE) |
| `400` | Malformed id — video IDs must match `[a-zA-Z0-9_-]{11}`, channel IDs `UC[a-zA-Z0-9_-]{22}` |
| `403` | Missing/invalid/expired Bearer token |
| `404` | Instance doesn't have this fork's API |

**Idempotent.** Blocking something already blocked is a `204`, not an error, and
so is unblocking something that was never blocked. No need to check first, and
no need to serialize rapid taps.

---

## 3. Where filtering happens

Two layers, because neither covers everything on its own.

**Server-side, automatic.** `GET /api/v1/videos/:id` strips blocked entries from
`recommendedVideos` — **but only if you send the Bearer token**. That endpoint is
public and normally unauthenticated; this fork makes it *optionally*
authenticated. Send the token and you get a filtered, user-specific response;
send nothing and you get the normal unfiltered one. An absent or expired token
is ignored rather than rejected, so it never 403s.

> **Caching caveat:** sending the token makes the response vary per user. If you
> cache video detail, either key the cache by account or don't send the token on
> requests whose results you share across accounts.

**Client-side, from the list.** The server can't filter surfaces that aren't
per-user — search results, channel tabs, playlists, trending. Fetch the list
once, keep it in memory, and filter those yourself. This also lets you render a
"blocked" state in your own UI rather than silently dropping rows.

---

## 4. Swift implementation

```swift
import Foundation

// MARK: - Models

struct NotRecommendedList: Codable {
    var videos: [String]
    var channels: [String]

    static let empty = NotRecommendedList(videos: [], channels: [])
}

enum NotRecommendKind {
    case video(String)      // 11-char video id
    case channel(String)    // UC… channel id

    var path: String {
        switch self {
        case .video(let id):    return "api/v1/auth/norecommend/videos/\(id)"
        case .channel(let id):  return "api/v1/auth/norecommend/channels/\(id)"
        }
    }
}

// MARK: - Client

actor NotRecommendStore {
    private let base: URL
    private let token: String          // the Bearer value from /authorize_token
    private var cache: Set<String> = []   // videos ∪ channels, for O(1) lookups
    private var loaded = false

    init(base: URL, token: String) {
        self.base = base
        self.token = token
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Load once per session (and after any mutation).
    @discardableResult
    func refresh() async throws -> NotRecommendedList {
        let (data, resp) = try await URLSession.shared.data(
            for: request("api/v1/auth/norecommend", method: "GET"))

        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            // 404 → instance lacks the fork API; treat as "feature off", not an error.
            if http.statusCode == 404 { loaded = true; cache = []; return .empty }
            throw URLError(.badServerResponse)
        }

        let list = try JSONDecoder().decode(NotRecommendedList.self, from: data)
        cache = Set(list.videos).union(list.channels)
        loaded = true
        return list
    }

    /// True if this video or its channel is blocked.
    func isBlocked(videoID: String?, channelID: String?) -> Bool {
        if let v = videoID, cache.contains(v) { return true }
        if let c = channelID, cache.contains(c) { return true }
        return false
    }

    func block(_ what: NotRecommendKind) async throws {
        try await mutate(what, method: "POST")
    }

    func unblock(_ what: NotRecommendKind) async throws {
        try await mutate(what, method: "DELETE")
    }

    private func mutate(_ what: NotRecommendKind, method: String) async throws {
        let (_, resp) = try await URLSession.shared.data(
            for: request(what.path, method: method))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 204 else {
            throw URLError(.badServerResponse)
        }
        // Keep the local set in step without a round-trip.
        let id: String
        switch what {
        case .video(let v):   id = v
        case .channel(let c): id = c
        }
        if method == "POST" { cache.insert(id) } else { cache.remove(id) }
    }
}
```

### Sending the token on video detail

To get server-side filtering of `recommendedVideos`, add the same header to the
existing video-detail fetch — no other change:

```swift
var req = URLRequest(url: base.appendingPathComponent("api/v1/videos/\(id)"))
req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")  // optional
let (data, _) = try await URLSession.shared.data(for: req)
```

---

## 5. Suggested UX

- **Where to offer it:** a context menu / long-press action on any video row —
  "Don't recommend this video" and "Don't recommend this channel". This mirrors
  YouTube's own affordance, so it needs no explanation.
- **Optimistic updates:** remove the row immediately, restore it if the request
  throws. Mutations are idempotent, so a retry is always safe.
- **A way back:** a settings screen listing both sets with a remove action.
  Without it, a mis-tap is unrecoverable from the client. The instance's own web
  UI has this at `/not_recommend_manager` if you'd rather link out at first.
- **Filter on render**, not on fetch — call `isBlocked` as rows are built, so
  newly blocked items disappear from already-loaded lists without a refetch.
- **Degrade quietly:** if `supportsForkAPIs` is false, hide the menu items and
  the settings screen entirely rather than showing errors.

---

## 6. Notes / limitations

- The block list is **per Invidious account**, stored server-side — it syncs
  across devices automatically, and it does not exist for logged-out users.
  Anything you want to work anonymously has to be local-only on the client.
- Blocking a channel does not unsubscribe from it, and a subscribed channel can
  still be blocked. They're independent — the subscription feed is not filtered
  by this list, only Discover and related videos.
- `youtubeAccessDegraded` is per-instance in-process state. It resets on restart
  and every ~10 minutes, and it is not persisted or shared between instances.
