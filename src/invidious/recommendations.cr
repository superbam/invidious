# Builds a personalized recommendation list from watch history: for a
# bounded window of recently-watched videos, pull each one's cached "related
# videos" and tally how often each candidate shows up across that window —
# a candidate suggested by more of what you watched ranks higher. Being from
# a subscribed channel is a secondary signal: it nudges the score of a
# candidate that already showed up this way, it doesn't add candidates of
# its own.
HISTORY_WINDOW    =  150
RECOMMENDED_COUNT =   60
SUBSCRIBED_BONUS  =    2

def fetch_recommendations(user : User) : Array(Video)
  watched_set = user.watched.to_set
  subscribed_ucids = user.subscriptions.to_set

  counts = Hash(String, Int32).new(0)
  from_subscription = Set(String).new

  user.watched.last(HISTORY_WINDOW).each do |source_id|
    source_video = begin
      get_video(source_id, refresh: false)
    rescue
      next
    end

    # De-dupe within one source video's own related list, so a single
    # heavily-cross-linked video can't dominate the tally by itself.
    seen_in_source = Set(String).new

    source_video.related_videos.each do |related|
      id = related["id"]
      next if watched_set.includes?(id)
      next unless seen_in_source.add?(id)

      counts[id] += 1
      from_subscription << id if subscribed_ucids.includes?(related["ucid"])
    end
  end

  ranked_ids = counts.keys.sort_by do |id|
    score = counts[id]
    score += SUBSCRIBED_BONUS if from_subscription.includes?(id)
    -score
  end

  videos = [] of Video
  ranked_ids.each do |id|
    break if videos.size >= RECOMMENDED_COUNT

    begin
      videos << get_video(id, refresh: false)
    rescue
      next
    end
  end

  videos
end
