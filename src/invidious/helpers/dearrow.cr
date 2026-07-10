# DeArrow prewarming — kicks off background lookups for videos about to be
# shown on a feed-style page (subscriptions, trending, popular, mix), so the
# comparatively slow, job-queued thumbnail generation on DeArrow's end has a
# head start before a viewer's browser gets around to lazily requesting the
# same video (see assets/js/dearrow_feed.js). Best-effort only: failures are
# swallowed, and nothing here blocks the page response.
module Invidious::Dearrow
  MAX_CONCURRENT_WARMERS = 6
  WARMED_CACHE_LIMIT     =  20_000

  @@queue = ::Channel(String).new(1000)
  @@warmed = Set(String).new
  @@mutex = Mutex.new
  @@started = false

  def self.prewarm(video_ids : Enumerable(String))
    start_workers

    video_ids.each do |id|
      next if id.empty?

      should_enqueue = false
      @@mutex.synchronize do
        unless @@warmed.includes?(id)
          @@warmed << id
          @@warmed.clear if @@warmed.size > WARMED_CACHE_LIMIT
          should_enqueue = true
        end
      end
      next unless should_enqueue

      # Non-blocking: if the queue is full, drop rather than stall the page
      # render that called us.
      select
      when @@queue.send(id)
      else
      end
    end
  end

  private def self.start_workers
    return if @@started
    @@mutex.synchronize do
      return if @@started
      @@started = true

      MAX_CONCURRENT_WARMERS.times do
        spawn do
          loop do
            id = @@queue.receive
            begin
              warm_one(id)
            rescue ex
              LOGGER.trace("Dearrow.prewarm: #{id} : #{ex.message}")
            end
          end
        end
      end
    end
  end

  private def self.warm_one(id : String)
    branding = HTTP::Client.get(
      "#{CONFIG.dearrow_url}/api/branding?videoID=#{URI.encode_www_form(id)}",
      HTTP::Headers{"User-Agent" => "Invidious/#{SOFTWARE["version"]}"}
    )
    return unless branding.status_code == 200

    thumbnails = JSON.parse(branding.body)["thumbnails"]?.try &.as_a?
    return unless thumbnails

    best = thumbnails.find do |t|
      original = t["original"]?.try &.as_bool?
      votes = t["votes"]?.try &.as_i?
      !original && votes && votes >= 0 && !as_timestamp(t["timestamp"]?).nil?
    end
    return unless best

    time = as_timestamp(best["timestamp"]?).not_nil!

    HTTP::Client.get(
      "#{CONFIG.dearrow_thumb_url}/api/v1/getThumbnail?videoID=#{URI.encode_www_form(id)}&time=#{URI.encode_www_form(time.to_s)}",
      HTTP::Headers{"User-Agent" => "Invidious/#{SOFTWARE["version"]}"}
    )
  end

  # DeArrow encodes whole-number timestamps as bare JSON integers (e.g. `0`),
  # which JSON::Any#as_f? doesn't recognize since it only matches values
  # already encoded as floats.
  private def self.as_timestamp(any : JSON::Any?) : Float64?
    return nil unless any

    case raw = any.raw
    when Float64 then raw
    when Int64   then raw.to_f
    else              nil
    end
  end
end
