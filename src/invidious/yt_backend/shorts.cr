require "json"

# Helpers for detecting YouTube Shorts.
#
# This is a *fork-only* feature. To keep it resilient against upstream Invidious
# changes, all Shorts-specific logic that would otherwise be scattered through
# upstream files is concentrated here. Call sites inside upstream files should be
# a single line into this module, wrapped in `# >>> shorts-filter` /
# `# <<< shorts-filter` markers so any future merge conflict is trivial to spot
# and re-apply. See MAINTAINING.md.
module Invidious::Shorts
  extend self

  # Detect whether an InnerTube video renderer (videoRenderer / richItem /
  # search result) represents a Short, given its "contents" JSON object.
  #
  # Mirrors NewPipe's isShortFormContent(): several OR'd signals, since no single
  # one is reliably present across surfaces:
  #   1. navigationEndpoint.commandMetadata.webCommandMetadata.webPageType == WEB_PAGE_TYPE_SHORTS
  #   2. navigationEndpoint contains a reelWatchEndpoint
  #   3. a thumbnailOverlayTimeStatusRenderer flagged as SHORTS (style / text / icon)
  def detect_in_renderer(item_contents : JSON::Any) : Bool
    web_page_type = item_contents.dig?(
      "navigationEndpoint", "commandMetadata", "webCommandMetadata", "webPageType"
    ).try(&.as_s?)
    return true if web_page_type == "WEB_PAGE_TYPE_SHORTS"

    return true if item_contents.dig?("navigationEndpoint", "reelWatchEndpoint")

    overlay = item_contents["thumbnailOverlays"]?.try(&.as_a?)
      .try(&.find(&.["thumbnailOverlayTimeStatusRenderer"]?))
      .try(&.["thumbnailOverlayTimeStatusRenderer"]?)

    if overlay
      return true if overlay.dig?("style").try(&.as_s?) == "SHORTS"
      return true if overlay.dig?("text", "simpleText").try(&.as_s?) == "SHORTS"

      icon = overlay.dig?("icon", "iconType").try(&.as_s?)
      return true if icon.try(&.downcase.includes?("shorts"))
    end

    false
  end
end
