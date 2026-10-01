# Builds a personalized "Discover" feed from watch history: for a bounded
# window of recently-watched videos, pull each one's cached "related
# videos" and score how often, how prominently, and how strongly each
# candidate shows up across that window. The goal is surfacing channels
# you *don't* already know, not more of what's already in your
# subscriptions feed — so a subscribed-channel candidate is penalized
# rather than boosted, and only candidates that are either genuinely
# popular or strongly/repeatedly recommended make the cut at all
# (QUALIFIES_MIN_VIEWS / QUALIFIES_MIN_FREQUENCY below — "and/or", either
# bar is enough). "Highly rated" isn't something YouTube's API exposes
# per-video anymore (no public like/dislike ratio), so it's read here as
# "strongly vouched for by more than one thing you watched".
#
# Candidates are rendered straight from the lightweight related-video data
# collected along the way (title/author/ucid/length/rough view count) rather
# than re-fetched individually: unlike the *source* videos (which are
# guaranteed already cached, since watching one is what caused it to be
# fetched), a "related but never watched" candidate usually isn't cached
# yet, and get_video() always does a live YouTube fetch for anything it
# can't find in Postgres regardless of the `refresh` flag. Re-fetching ~60
# of those one at a time was the entire cost of loading this page.
HISTORY_WINDOW          =     150
DISCOVER_COUNT          =      24
SUBSCRIBED_PENALTY      =    -1.5
VIEWS_WEIGHT            =    0.15
RECENCY_WEIGHT          =     0.5
RECENCY_WINDOW_DAYS     =     730
QUALIFIES_MIN_VIEWS     = 100_000
QUALIFIES_MIN_FREQUENCY =     1.5
FETCH_CONCURRENCY       =      10
CACHE_TTL               = 15.minutes
CACHE_MIN_REFRESH       = 2.minutes
CACHE_MAX_USERS         = 256

record DiscoverVideo,
  id : String,
  title : String,
  author : String,
  ucid : String,
  length_seconds : Int32,
  views : Int64,
  published : Time,
  author_verified : Bool,
  premiere_timestamp : Time? = nil do
  def live_now
    false
  end

  def to_json(locale : String?, json : JSON::Builder)
    json.object do
      json.field "type", "video"

      json.field "title", self.title
      json.field "videoId", self.id
      json.field "videoThumbnails" do
        Invidious::JSONify::APIv1.thumbnails(json, self.id)
      end

      json.field "lengthSeconds", self.length_seconds

      json.field "author", self.author
      json.field "authorId", self.ucid
      json.field "authorUrl", "/channel/#{self.ucid}"
      json.field "authorVerified", self.author_verified

      json.field "published", self.published.to_unix
      json.field "publishedText", I18n.translate(locale, "`x` ago", recode_date(self.published, locale))

      json.field "viewCount", self.views
      json.field "liveNow", self.live_now
    end
  end

  def to_json(locale : String?, _json : Nil = nil)
    JSON.build do |json|
      to_json(locale, json)
    end
  end
end

def fetch_discover(user : Invidious::User, page : Int32 = 1) : {Array(DiscoverVideo), Bool}
  DiscoverCache.fetch(user, page)
end

# The expensive part: reads up to HISTORY_WINDOW cached videos and ranks every
# candidate. Returns the *whole* ranked list (not one page) so the result can
# be cached per user and sliced cheaply on each request.
def build_discover_ranking(user : Invidious::User) : Array(DiscoverVideo)
  source_videos = fetch_videos_concurrently(user.watched.last(HISTORY_WINDOW))
  # Mirrors fetch_videos_concurrently's own per-video rescue below: unexpected
  # related-video markup for one source video (YouTube changes this shape
  # periodically) must not 500 the whole Discover response — just drop that
  # source video's contribution to the ranking.
  related_lists = source_videos.compact_map do |video|
    begin
      video.related_videos
    rescue
      nil
    end
  end

  rank_discover_all(
    related_lists, user.watched, user.subscriptions,
    blocked: Invidious::Database::NotRecommended.select_all(user)
  )
end

# Per-user cache of the ranked Discover list, so opening the tab doesn't wait
# on ~150 video reads plus a re-rank.
#
# - A request is always served from the cache when an entry exists, even a
#   stale one; staleness only triggers a background rebuild. The served list
#   is re-filtered against the user's *current* watched and don't-recommend
#   sets, so "I just watched/blocked this" takes effect immediately.
# - `warm` is called on ordinary page loads, so the first build happens while
#   the user is still on another page rather than when they click Discover.
# - Concurrent builds for one user are collapsed into one.
module DiscoverCache
  record Entry, ranked : Array(DiscoverVideo), signature : UInt64, computed_at : Time

  @@entries = Hash(String, Entry).new
  @@building = Hash(String, ::Channel(Nil)).new
  @@mutex = Mutex.new

  def self.fetch(user : Invidious::User, page : Int32) : {Array(DiscoverVideo), Bool}
    entry = @@mutex.synchronize { @@entries[user.email]? }

    if entry
      refresh_in_background(user) if stale?(entry, user)
      ranked = entry.ranked
    else
      ranked = build(user)
    end

    blocked = Invidious::Database::NotRecommended.select_all(user)
    paginate(ranked, user.watched.to_set, blocked, page)
  end

  # Start a background build if this user has no fresh entry. Cheap no-op
  # otherwise, so it's safe to call from every page load.
  def self.warm(user : Invidious::User) : Nil
    entry = @@mutex.synchronize { @@entries[user.email]? }
    refresh_in_background(user) if entry.nil? || stale?(entry, user)
  end

  def self.clear : Nil
    @@mutex.synchronize { @@entries.clear }
  end

  # Drops what the user has since watched or blocked from a cached list and
  # slices out one page. Pure, so it's covered by specs without a DB.
  def self.paginate(
    ranked : Array(DiscoverVideo),
    watched : Set(String),
    blocked : Invidious::NotRecommended::Blocked,
    page : Int32,
  ) : {Array(DiscoverVideo), Bool}
    visible = ranked.reject { |v| watched.includes?(v.id) || blocked.blocks?(v.id, v.ucid) }

    offset = (page - 1) * DISCOVER_COUNT
    page_videos = visible[offset, DISCOVER_COUNT]? || [] of DiscoverVideo
    {page_videos, visible.size > offset + page_videos.size}
  end

  # What a ranking depends on. Blocked entries are deliberately absent: a new
  # block is applied at read time, and an unblock isn't worth a rebuild by
  # itself.
  private def self.signature(user : Invidious::User) : UInt64
    {user.watched.last(HISTORY_WINDOW), user.subscriptions}.hash
  end

  private def self.stale?(entry : Entry, user : Invidious::User) : Bool
    age = Time.utc - entry.computed_at
    return true if age > CACHE_TTL
    # Watching something or (un)subscribing changes the inputs, but rebuilding
    # on every single watch would be wasteful — rate-limit it.
    age > CACHE_MIN_REFRESH && entry.signature != signature(user)
  end

  private def self.refresh_in_background(user : Invidious::User) : Nil
    spawn do
      begin
        build(user)
      rescue ex
        LOGGER.warn("discover: background refresh failed for a user: #{ex.message}")
      end
    end
  end

  # Builds and stores this user's ranking, or — if a build is already running
  # — waits for it and uses its result.
  private def self.build(user : Invidious::User) : Array(DiscoverVideo)
    email = user.email
    waiting_on = nil
    mine = nil

    @@mutex.synchronize do
      if running = @@building[email]?
        waiting_on = running
      else
        mine = @@building[email] = ::Channel(Nil).new
      end
    end

    if waiting_on
      waiting_on.receive?
      if entry = @@mutex.synchronize { @@entries[email]? }
        return entry.ranked
      end
      # The build we waited on failed; fall back to computing it ourselves.
      return build_discover_ranking(user)
    end

    begin
      inputs = signature(user)
      ranked = build_discover_ranking(user)
      store(email, Entry.new(ranked, inputs, Time.utc))
      ranked
    ensure
      @@mutex.synchronize { @@building.delete(email) }
      mine.try &.close
    end
  end

  private def self.store(email : String, entry : Entry) : Nil
    @@mutex.synchronize do
      @@entries[email] = entry

      if @@entries.size > CACHE_MAX_USERS
        oldest = @@entries.min_by { |_, e| e.computed_at }[0]
        @@entries.delete(oldest)
      end
    end
  end
end

# Pure ranking/exclusion logic, split out from fetch_discover so it's
# testable without a live DB or network call. `watched` and `subscriptions`
# are always the user's *complete* history/subscriptions here — capping how
# many watched videos are used as *sources* (HISTORY_WINDOW, applied by the
# caller before this function ever sees the list) only limits how many
# candidates get generated, it must never limit which candidates get
# excluded for already being watched.
#
# `blocked` is the user's "don't recommend" list; a candidate matching it by
# either video id or channel is dropped outright rather than down-ranked —
# unlike the subscription penalty, this is an explicit "never show me this"
# instruction, so no amount of other signal should be able to override it.
def rank_discover(
  related_lists : Array(Array(Hash(String, String))),
  watched : Array(String),
  subscriptions : Array(String),
  page : Int32 = 1,
  blocked : Invidious::NotRecommended::Blocked = Invidious::NotRecommended::EMPTY,
) : {Array(DiscoverVideo), Bool}
  ranked = rank_discover_all(related_lists, watched, subscriptions, blocked: blocked)

  offset = (page - 1) * DISCOVER_COUNT
  page_videos = ranked[offset, DISCOVER_COUNT]? || [] of DiscoverVideo

  {page_videos, ranked.size > offset + page_videos.size}
end

# The full ranked list; rank_discover and DiscoverCache both slice pages out
# of it.
def rank_discover_all(
  related_lists : Array(Array(Hash(String, String))),
  watched : Array(String),
  subscriptions : Array(String),
  blocked : Invidious::NotRecommended::Blocked = Invidious::NotRecommended::EMPTY,
) : Array(DiscoverVideo)
  watched_set = watched.to_set
  subscribed_ucids = subscriptions.to_set

  frequency_scores = Hash(String, Float64).new(0.0)
  from_subscription = Set(String).new
  candidate_info = Hash(String, Hash(String, String)).new

  related_lists.each do |related_videos|
    # De-dupe within one source video's own related list, so a single
    # heavily-cross-linked video can't dominate the tally by itself.
    seen_in_source = Set(String).new

    related_videos.each_with_index do |related, position|
      id = related["id"]
      next if watched_set.includes?(id)
      next if blocked.blocks?(id, related["ucid"]?)
      next unless seen_in_source.add?(id)

      # YouTube orders each related-videos list by relevance, so a
      # candidate found near the top of a source's list is a stronger
      # signal than one found near the bottom.
      frequency_scores[id] += 1.0 / (position + 1)
      candidate_info[id] ||= related
      from_subscription << id if subscribed_ucids.includes?(related["ucid"])
    end
  end

  qualifying_ids = frequency_scores.keys.select do |id|
    views = short_text_to_number(candidate_info[id]["short_view_count"])
    views >= QUALIFIES_MIN_VIEWS || frequency_scores[id] >= QUALIFIES_MIN_FREQUENCY
  end

  ranked_ids = qualifying_ids.sort_by do |id|
    -final_score(frequency_scores[id], candidate_info[id], from_subscription.includes?(id))
  end

  ranked_ids.map { |id| build_discover_video(candidate_info[id]) }
end

# Combines the position/frequency signal with the secondary bumps: a
# subscribed-channel candidate gets pushed down (this feed is for finding
# channels you don't already follow — see module comment), while the
# candidate's own popularity (log-scaled, since view counts span several
# orders of magnitude) and recency (fades linearly to 0 over
# RECENCY_WINDOW_DAYS — "slightly preferred", not a hard requirement) both
# nudge it up.
private def final_score(frequency_score : Float64, info : Hash(String, String), subscribed : Bool) : Float64
  score = frequency_score
  score += SUBSCRIBED_PENALTY if subscribed
  score += Math.log10(short_text_to_number(info["short_view_count"]).to_f + 1) * VIEWS_WEIGHT
  score += recency_bonus(info["published"])
  score
end

private def recency_bonus(published : String) : Float64
  return 0.0 if published.empty?

  published_time = begin
    Time.parse_rfc3339(published)
  rescue
    return 0.0
  end

  age_days = (Time.utc - published_time).total_days
  return 0.0 if age_days < 0 || age_days > RECENCY_WINDOW_DAYS

  (1.0 - age_days / RECENCY_WINDOW_DAYS) * RECENCY_WEIGHT
end

private def fetch_videos_concurrently(ids : Array(String)) : Array(Video)
  return [] of Video if ids.empty?

  queue = ::Channel(String).new(ids.size)
  ids.each { |id| queue.send(id) }
  queue.close

  results = [] of Video
  mutex = Mutex.new
  done = ::Channel(Nil).new

  FETCH_CONCURRENCY.times do
    spawn do
      loop do
        id = begin
          queue.receive
        rescue Channel::ClosedError
          break
        end

        begin
          video = get_video(id, refresh: false)
          mutex.synchronize { results << video }
        rescue
          # Video unavailable/deleted since it was watched; skip it.
        end
      end

      done.send(nil)
    end
  end

  FETCH_CONCURRENCY.times { done.receive }

  results
end

private def build_discover_video(info : Hash(String, String)) : DiscoverVideo
  published = begin
    Time.parse_rfc3339(info["published"])
  rescue
    Time.utc
  end

  DiscoverVideo.new(
    id: info["id"],
    title: info["title"],
    author: info["author"],
    ucid: info["ucid"],
    length_seconds: info["length_seconds"].to_i? || 0,
    views: short_text_to_number(info["short_view_count"]),
    published: published,
    author_verified: info["author_verified"] == "true",
  )
end
