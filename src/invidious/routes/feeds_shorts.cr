# shorts-filter: Shorts-related feed routes kept out of the upstream feeds.cr
# to minimise the conflict surface there. The module is reopened; the glob
# `require "./routes/**"` picks this file up automatically. See MAINTAINING.md.
module Invidious::Routes::Feeds
  # One-off backfill: re-check existing subscription-feed rows that predate
  # reliable Short detection and flag the ones that are actually Shorts.
  # Runs in the background (each check is a network request) and logs progress.
  def self.backfill_shorts(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    referer = get_referer(env, "/feed/subscriptions")
    return env.redirect referer if !user
    user = user.as(User)

    # On instances that define admins, restrict the backfill to them. On a
    # personal instance with no admins configured, any logged-in user may run it.
    if !CONFIG.admins.empty? && !CONFIG.admins.includes?(user.email)
      return error_template(403, "Only an administrator can run the Shorts backfill.")
    end

    limit = env.params.query["limit"]?.try &.to_i?.try &.clamp(1, 5000)
    limit ||= 1000

    videos = Invidious::Database::ChannelVideos.select_not_short(user.subscriptions, limit)

    spawn do
      marked = 0
      videos.each do |video|
        if video_is_short?(video.id)
          Invidious::Database::ChannelVideos.mark_short(video.id)
          marked += 1
        end
        # Be gentle on the InnerTube endpoint.
        sleep 200.milliseconds
      end
      LOGGER.info("backfill_shorts: #{user.email} : marked #{marked}/#{videos.size} videos as Shorts")
    end

    env.response.content_type = "text/html"
    %(<p>Shorts backfill started for #{videos.size} videos. This runs in the background; \
refresh your feed shortly. <a href="#{referer}">Back to subscriptions</a>.</p>)
  end
end
