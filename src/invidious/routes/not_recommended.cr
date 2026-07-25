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
      Invidious::Database::NotRecommended.insert(user, kind, target)
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

    blocked = Invidious::Database::NotRecommended.select_all(user)

    # Resolve channel ids to names where we already have them cached, so the
    # list is readable; an unknown channel just renders as its raw ucid.
    channels = Invidious::Database::Channels.select(blocked.channels.to_a)
      .try(&.to_h { |channel| {channel.id, channel.author} }) || {} of String => String

    templated "user/not_recommended_manager"
  end

  private def self.valid_target?(kind : Invidious::Database::NotRecommended::Kind, target : String) : Bool
    case kind
    in .video?   then !!target.match(/^[a-zA-Z0-9_-]{11}$/)
    in .channel? then !!target.match(/^UC[a-zA-Z0-9_-]{22}$/)
    end
  end
end
