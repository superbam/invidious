# Builds a personalized recommendation list from watch history: for a
# bounded window of recently-watched videos, pull each one's cached "related
# videos" and tally how often each candidate shows up across that window —
# a candidate suggested by more of what you watched ranks higher. Being from
# a subscribed channel is a secondary signal: it nudges the score of a
# candidate that already showed up this way, it doesn't add candidates of
# its own.
#
# Candidates are rendered straight from the lightweight related-video data
# collected along the way (title/author/ucid/length/rough view count) rather
# than re-fetched individually: unlike the *source* videos (which are
# guaranteed already cached, since watching one is what caused it to be
# fetched), a "related but never watched" candidate usually isn't cached
# yet, and get_video() always does a live YouTube fetch for anything it
# can't find in Postgres regardless of the `refresh` flag. Re-fetching ~60
# of those one at a time was the entire cost of loading this page.
HISTORY_WINDOW    =  150
RECOMMENDED_COUNT =   60
SUBSCRIBED_BONUS  =    2
FETCH_CONCURRENCY =   10

record RecommendedVideo,
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
end

def fetch_recommendations(user : Invidious::User, page : Int32 = 1) : {Array(RecommendedVideo), Bool}
  source_videos = fetch_videos_concurrently(user.watched.last(HISTORY_WINDOW))
  related_lists = source_videos.map(&.related_videos)

  rank_recommendations(related_lists, user.watched, user.subscriptions, page)
end

# Pure ranking/exclusion logic, split out from fetch_recommendations so it's
# testable without a live DB or network call. `watched` and `subscriptions`
# are always the user's *complete* history/subscriptions here — capping how
# many watched videos are used as *sources* (HISTORY_WINDOW, applied by the
# caller before this function ever sees the list) only limits how many
# candidates get generated, it must never limit which candidates get
# excluded for already being watched.
def rank_recommendations(
  related_lists : Array(Array(Hash(String, String))),
  watched : Array(String),
  subscriptions : Array(String),
  page : Int32 = 1,
) : {Array(RecommendedVideo), Bool}
  watched_set = watched.to_set
  subscribed_ucids = subscriptions.to_set

  counts = Hash(String, Int32).new(0)
  from_subscription = Set(String).new
  candidate_info = Hash(String, Hash(String, String)).new

  related_lists.each do |related_videos|
    # De-dupe within one source video's own related list, so a single
    # heavily-cross-linked video can't dominate the tally by itself.
    seen_in_source = Set(String).new

    related_videos.each do |related|
      id = related["id"]
      next if watched_set.includes?(id)
      next unless seen_in_source.add?(id)

      counts[id] += 1
      candidate_info[id] ||= related
      from_subscription << id if subscribed_ucids.includes?(related["ucid"])
    end
  end

  ranked_ids = counts.keys.sort_by do |id|
    score = counts[id]
    score += SUBSCRIBED_BONUS if from_subscription.includes?(id)
    -score
  end

  # The full ranking is recomputed every page (no caching, see module
  # comment history), so pagination only changes which slice gets turned
  # into full RecommendedVideo objects to render — the underlying tally
  # above is the same work either way.
  offset = (page - 1) * RECOMMENDED_COUNT
  page_ids = ranked_ids[offset, RECOMMENDED_COUNT]? || [] of String
  has_more = ranked_ids.size > offset + page_ids.size

  videos = page_ids.map { |id| build_recommended_video(candidate_info[id]) }

  {videos, has_more}
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

private def build_recommended_video(info : Hash(String, String)) : RecommendedVideo
  published = begin
    Time.parse_rfc3339(info["published"])
  rescue
    Time.utc
  end

  RecommendedVideo.new(
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
