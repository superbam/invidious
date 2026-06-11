require "../../parsers_helper.cr"

# shorts-filter smoke test. Guards against *semantic* breakage: upstream can
# refactor the extractor in a way that merges cleanly but silently stops Shorts
# from being detected. These fixtures are minimal InnerTube renderer fragments,
# one per detection signal, so the test needs no network or database. If a merge
# turns any of these red, the Shorts feature is broken even if it still compiles.
Spectator.describe Invidious::Shorts do
  describe "#detect_in_renderer" do
    it "detects a Short via navigationEndpoint webPageType" do
      renderer = JSON.parse(%({
        "navigationEndpoint": {
          "commandMetadata": {
            "webCommandMetadata": { "webPageType": "WEB_PAGE_TYPE_SHORTS" }
          }
        }
      }))
      expect(described_class.detect_in_renderer(renderer)).to be_true
    end

    it "detects a Short via reelWatchEndpoint" do
      renderer = JSON.parse(%({
        "navigationEndpoint": { "reelWatchEndpoint": { "videoId": "abcdefghijk" } }
      }))
      expect(described_class.detect_in_renderer(renderer)).to be_true
    end

    it "detects a Short via SHORTS thumbnail overlay style" do
      renderer = JSON.parse(%({
        "thumbnailOverlays": [
          { "thumbnailOverlayTimeStatusRenderer": { "style": "SHORTS" } }
        ]
      }))
      expect(described_class.detect_in_renderer(renderer)).to be_true
    end

    it "detects a Short via SHORTS thumbnail overlay text" do
      renderer = JSON.parse(%({
        "thumbnailOverlays": [
          { "thumbnailOverlayTimeStatusRenderer": { "text": { "simpleText": "SHORTS" } } }
        ]
      }))
      expect(described_class.detect_in_renderer(renderer)).to be_true
    end

    it "does not flag a regular video" do
      renderer = JSON.parse(%({
        "navigationEndpoint": {
          "commandMetadata": { "webCommandMetadata": { "webPageType": "WEB_PAGE_TYPE_WATCH" } }
        },
        "thumbnailOverlays": [
          {
            "thumbnailOverlayTimeStatusRenderer": {
              "style": "DEFAULT",
              "text": { "simpleText": "10:23" }
            }
          }
        ]
      }))
      expect(described_class.detect_in_renderer(renderer)).to be_false
    end

    it "does not flag an empty renderer" do
      expect(described_class.detect_in_renderer(JSON.parse("{}"))).to be_false
    end
  end
end
