# Builds a personalized recommendation list from watch history: for a
# bounded window of recently-watched videos, pull each one's cached "related
# videos" and score how often, how prominently, and how strongly each
# candidate shows up across that window. Being from a subscribed channel,
# the candidate's own popularity, and how recent it is are secondary
# signals layered on top — they nudge the score of a candidate that
# already showed up this way, they don't add candidates of their own.
#
# Candidates are rendered straight from the lightweight related-video data
# collected along the way (title/author/ucid/length/rough view count) rather
# than re-fetched individually: unlike the *source* videos (which are
# guaranteed already cached, since watching one is what caused it to be
# fetched), a "related but never watched" candidate usually isn't cached
# yet, and get_video() always does a live YouTube fetch for anything it
# can't find in Postgres regardless of the `refresh` flag. Re-fetching ~60
# of those one at a time was the entire cost of loading this page.
HISTORY_WINDOW      =  150
RECOMMENDED_COUNT   =   60
SUBSCRIBED_BONUS    =  0.5
VIEWS_WEIGHT        = 0.15
RECENCY_WEIGHT      =  0.5
RECENCY_WINDOW_DAYS = 730
FETCH_CONCURRENCY   =   10

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
      next unless seen_in_source.add?(id)

      # YouTube orders each related-videos list by relevance, so a
      # candidate found near the top of a source's list is a stronger
      # signal than one found near the bottom.
      frequency_scores[id] += 1.0 / (position + 1)
      candidate_info[id] ||= related
      from_subscription << id if subscribed_ucids.includes?(related["ucid"])
    end
  end

  ranked_ids = frequency_scores.keys.sort_by do |id|
    -final_score(frequency_scores[id], candidate_info[id], from_subscription.includes?(id))
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

# Combines the position/frequency signal with the secondary bumps: being
# from a subscribed channel, the candidate's own popularity (log-scaled,
# since view counts span several orders of magnitude), and recency (fades
# linearly to 0 over RECENCY_WINDOW_DAYS — "slightly preferred", not a
# hard requirement).
private def final_score(frequency_score : Float64, info : Hash(String, String), subscribed : Bool) : Float64
  score = frequency_score
  score += SUBSCRIBED_BONUS if subscribed
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
