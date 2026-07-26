#
# shorts-filter: web routes for the per-user "don't recommend" list.
#
# The equivalent JSON API lives at /api/v1/auth/norecommend (see
# routes/api/v1/authenticated.cr); this is the browser-facing half — a
# CSRF-protected ajax endpoint for the buttons on the watch page's related
# videos, and a management page to review and undo entries.
#
module Invidious::Routes::NotRecommended
  def self.ajax(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env, "/")

    redirect = env.params.query["redirect"]?
    redirect ||= "true"
    redirect = redirect == "true"

    if !user
      if redirect
        return env.redirect referer
      else
        return error_json(403, "No such user")
      end
    end

    user = user.as(User)
    sid = sid.as(String)
    token = env.params.body["csrf_token"]?

    begin
      validate_request(token, sid, env.request, HMAC_KEY, locale)
    rescue ex
      if redirect
        return error_template(400, ex)
      else
        return error_json(400, ex)
      end
    end

    kind = case env.params.query["kind"]?
           when "video"   then Invidious::Database::NotRecommended::Kind::Video
           when "channel" then Invidious::Database::NotRecommended::Kind::Channel
           else                nil
           end

    if kind.nil?
      return error_json(400, "Invalid kind, expected \"video\" or \"channel\".")
    end

    target = env.params.query["target"]?
    if target.nil? || !valid_target?(kind, target)
      return error_json(400, "Invalid target id.")
    end

    case action = env.params.query["action"]?
    when "add"
      # The label to show on the management page, captured from whatever the
      # user was looking at. Truncated because it's free text off the page and
      # only ever needs to be recognisable in a list.
      title = env.params.query["title"]?.presence.try { |t| t.size > 200 ? t[0, 200] : t }
      Invidious::Database::NotRecommended.insert(user, kind, target, title)
    when "remove"
      Invidious::Database::NotRecommended.delete(user, kind, target)
    else
      return error_json(400, "Unsupported action #{action}")
    end

    if redirect
      env.redirect referer
    else
      env.response.content_type = "application/json"
      "{}"
    end
  end

  def self.manager(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    referer = get_referer(env, "/")

    return env.redirect referer if !user
    user = user.as(User)

    entries = Invidious::Database::NotRecommended.select_entries(user)

    # Entries added before titles were stored (or via an API client that sent
    # none) fall back to the local channels cache, then to the bare id.
    untitled_ucids = entries
      .select { |e| e.kind.channel? && e.title.nil? }
      .map(&.target_id)

    cached_names = Invidious::Database::Channels.select(untitled_ucids)
      .try(&.to_h { |channel| {channel.id, channel.author} }) || {} of String => String

    blocked_channels = entries.select(&.kind.channel?)
      .sort_by! { |e| (e.title || cached_names[e.target_id]? || e.target_id).downcase }
    blocked_videos = entries.select(&.kind.video?).sort_by!(&.created).reverse!

    templated "user/not_recommended_manager"
  end

  private def self.valid_target?(kind : Invidious::Database::NotRecommended::Kind, target : String) : Bool
    case kind
    in .video?   then !!target.match(/^[a-zA-Z0-9_-]{11}$/)
    in .channel? then !!target.match(/^UC[a-zA-Z0-9_-]{22}$/)
    end
  end
end
