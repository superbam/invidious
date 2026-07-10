require "../spec_helper"

private def fake_related(
  id : String,
  ucid : String = "UC_default",
  views : String = "100",
  published : String = "",
) : Hash(String, String)
  {
    "id"               => id,
    "title"            => "Title for #{id}",
    "author"           => "Author",
    "ucid"             => ucid,
    "length_seconds"   => "120",
    "short_view_count" => views,
    "author_verified"  => "false",
    "published"        => published,
  }
end

Spectator.describe "rank_recommendations" do
  it "excludes a candidate found anywhere in the full watch history, not just the recent window used to generate candidates" do
    # "old_watched" simulates a video watched long ago — outside whatever
    # window the caller used to pick which videos to walk for candidates —
    # while still being present in the *full* watched list passed in here.
    related_lists = [[fake_related("old_watched"), fake_related("fresh_candidate")]]

    videos, _has_more = rank_recommendations(related_lists, ["old_watched"], [] of String)

    ids = videos.map(&.id)
    expect(ids).to_not contain("old_watched")
    expect(ids).to contain("fresh_candidate")
  end

  it "includes candidates that aren't in watch history" do
    related_lists = [[fake_related("candidate_a")]]

    videos, _has_more = rank_recommendations(related_lists, [] of String, [] of String)

    expect(videos.map(&.id)).to eq(["candidate_a"])
  end

  it "ranks a candidate suggested by more watched videos higher" do
    related_lists = [
      [fake_related("popular"), fake_related("rare")],
      [fake_related("popular")],
    ]

    videos, _has_more = rank_recommendations(related_lists, [] of String, [] of String)

    expect(videos.map(&.id)).to eq(["popular", "rare"])
  end

  it "ranks a candidate found higher (earlier) in a related-videos list above one found lower, all else equal" do
    # Same single source list, same views/publish-date defaults for both —
    # the only difference is position (0 vs 1), so it isolates that signal.
    related_lists = [
      [fake_related("top"), fake_related("buried")],
    ]

    videos, _has_more = rank_recommendations(related_lists, [] of String, [] of String)

    expect(videos.map(&.id)).to eq(["top", "buried"])
  end

  it "gives a subscribed channel's candidate a bump over an equally-ranked, equally-suggested one" do
    # Same position (0) in separate source lists, so frequency/position
    # scores tie exactly — the only difference is subscription status.
    related_lists = [
      [fake_related("from_subscribed", ucid: "UC_subscribed")],
      [fake_related("from_other", ucid: "UC_other")],
    ]

    videos, _has_more = rank_recommendations(related_lists, [] of String, ["UC_subscribed"])

    expect(videos.map(&.id)).to eq(["from_subscribed", "from_other"])
  end

  it "gives a more-viewed candidate a bump over an equally-ranked, equally-suggested one" do
    related_lists = [
      [fake_related("more_views", views: "5M")],
      [fake_related("fewer_views", views: "100")],
    ]

    videos, _has_more = rank_recommendations(related_lists, [] of String, [] of String)

    expect(videos.map(&.id)).to eq(["more_views", "fewer_views"])
  end

  it "gives a newer candidate a bump over an equally-ranked, equally-suggested older one" do
    related_lists = [
      [fake_related("newer", published: (Time.utc - 1.day).to_rfc3339)],
      [fake_related("older", published: (Time.utc - 700.days).to_rfc3339)],
    ]

    videos, _has_more = rank_recommendations(related_lists, [] of String, [] of String)

    expect(videos.map(&.id)).to eq(["newer", "older"])
  end

  it "doesn't let recency or popularity override a much stronger frequency/position signal" do
    related_lists = [
      [fake_related("strong_signal", views: "10", published: (Time.utc - 5.years).to_rfc3339)],
      [fake_related("strong_signal", views: "10", published: (Time.utc - 5.years).to_rfc3339)],
      [fake_related("strong_signal", views: "10", published: (Time.utc - 5.years).to_rfc3339)],
      [fake_related("weak_signal", views: "50M", published: (Time.utc - 1.day).to_rfc3339)],
    ]

    videos, _has_more = rank_recommendations(related_lists, [] of String, [] of String)

    expect(videos.map(&.id)).to eq(["strong_signal", "weak_signal"])
  end

  it "paginates: has_more is true when more candidates remain, false on the last page" do
    related_lists = [(0...(RECOMMENDED_COUNT + 5)).map { |i| fake_related("video_#{i}") }]

    page1, has_more1 = rank_recommendations(related_lists, [] of String, [] of String, page: 1)
    page2, has_more2 = rank_recommendations(related_lists, [] of String, [] of String, page: 2)

    expect(page1.size).to eq(RECOMMENDED_COUNT)
    expect(has_more1).to be_true

    expect(page2.size).to eq(5)
    expect(has_more2).to be_false

    expect(page1.map(&.id).to_set & page2.map(&.id).to_set).to be_empty
  end
end
