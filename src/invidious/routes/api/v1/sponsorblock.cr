module Invidious::Routes::API::V1::SponsorBlock
  VALID_CATEGORIES = {
    "sponsor", "selfpromo", "interaction", "intro", "outro",
    "preview", "music_offtopic", "filler", "poi_highlight",
    "exclusive_access", "chapter",
  }

  # ---------------------------------------------------------------------------
  # SponsorBlock — skip segment timings
  # ---------------------------------------------------------------------------

  def self.timings(env)
    env.response.content_type = "application/json"

    id = env.params.url["id"]

    if id.size != 11 || !id.matches?(/^[\w-]+$/)
      return error_json(400, "Invalid video ID")
    end

    raw_cats = env.params.query["categories"]?
    raw_cats ||= "sponsor"

    categories = raw_cats.split(",")
      .map(&.strip)
      .select { |c| VALID_CATEGORIES.includes?(c) }
      .uniq

    if categories.empty?
      return error_json(400, "No valid categories specified")
    end

    category_params = categories.map { |c| "category=#{URI.encode_www_form(c)}" }.join("&")
    url = "#{CONFIG.sponsorblock_url}/api/skipSegments?videoID=#{URI.encode_www_form(id)}&#{category_params}"

    begin
      response = HTTP::Client.get(url, HTTP::Headers{"User-Agent" => "Invidious/#{SOFTWARE["version"]}"})

      case response.status_code
      when 200 then return response.body
      when 404 then return "[]"
      when 429 then return error_json(429, "SponsorBlock rate limit exceeded")
      else          return error_json(response.status_code, "SponsorBlock API error")
      end
    rescue ex
      return error_json(500, "Failed to reach SponsorBlock: #{ex.message}")
    end
  end

  # ---------------------------------------------------------------------------
  # DeArrow — crowd-sourced branding (title + thumbnail timestamp)
  # ---------------------------------------------------------------------------

  def self.branding(env)
    env.response.content_type = "application/json"

    id = env.params.url["id"]

    if id.size != 11 || !id.matches?(/^[\w-]+$/)
      return error_json(400, "Invalid video ID")
    end

    url = "#{CONFIG.dearrow_url}/api/branding?videoID=#{URI.encode_www_form(id)}"

    begin
      response = HTTP::Client.get(url, HTTP::Headers{"User-Agent" => "Invidious/#{SOFTWARE["version"]}"})

      case response.status_code
      when 200 then return response.body
      when 404 then return %({"titles":[],"thumbnails":[]})
      when 429 then return error_json(429, "DeArrow rate limit exceeded")
      else          return error_json(response.status_code, "DeArrow API error")
      end
    rescue ex
      return error_json(500, "Failed to reach DeArrow: #{ex.message}")
    end
  end

  # ---------------------------------------------------------------------------
  # DeArrow thumbnail — proxy the frame-grab service
  # ---------------------------------------------------------------------------

  def self.thumbnail(env)
    id = env.params.url["id"]

    if id.size != 11 || !id.matches?(/^[\w-]+$/)
      env.response.content_type = "application/json"
      return error_json(400, "Invalid video ID")
    end

    time = env.params.query["time"]?
    unless time && time.to_f?
      env.response.content_type = "application/json"
      return error_json(400, "Missing or invalid time parameter")
    end

    url = "#{CONFIG.dearrow_thumb_url}/api/v1/getThumbnail" \
          "?videoID=#{URI.encode_www_form(id)}&time=#{URI.encode_www_form(time)}"

    begin
      response = HTTP::Client.get(url, HTTP::Headers{"User-Agent" => "Invidious/#{SOFTWARE["version"]}"})

      case response.status_code
      when 200
        env.response.content_type = response.headers["Content-Type"]? || "image/jpeg"
        env.response.headers["Cache-Control"] = "public, max-age=3600"
        return response.body
      when 404
        env.response.content_type = "application/json"
        return error_json(404, "No thumbnail available")
      else
        env.response.content_type = "application/json"
        return error_json(response.status_code, "DeArrow thumbnail error")
      end
    rescue ex
      env.response.content_type = "application/json"
      return error_json(500, "Failed to reach DeArrow thumbnail service: #{ex.message}")
    end
  end
end
