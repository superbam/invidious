module Invidious::Routes::API::V1::SponsorBlock
  VALID_CATEGORIES = {
    "sponsor", "selfpromo", "interaction", "intro", "outro",
    "preview", "music_offtopic", "filler", "poi_highlight",
    "exclusive_access", "chapter",
  }

  SPONSORBLOCK_API = "https://sponsor.ajay.app"

  def self.timings(env)
    env.response.content_type = "application/json"

    id = env.params.url["id"]

    if id.size != 11 || !id.matches?(/^[\w-]+$/)
      return error_json(400, "Invalid video ID")
    end

    # Parse and validate categories from comma-separated query param
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
    url = "#{SPONSORBLOCK_API}/api/skipSegments?videoID=#{URI.encode_www_form(id)}&#{category_params}"

    begin
      response = HTTP::Client.get(url, HTTP::Headers{"User-Agent" => "Invidious/#{SOFTWARE["version"]}"})

      case response.status_code
      when 200
        return response.body
      when 404
        return "[]"
      when 429
        return error_json(429, "SponsorBlock rate limit exceeded")
      else
        return error_json(response.status_code, "SponsorBlock API error")
      end
    rescue ex
      return error_json(500, "Failed to reach SponsorBlock: #{ex.message}")
    end
  end
end
