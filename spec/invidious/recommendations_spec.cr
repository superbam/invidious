require "../spec_helper"

private def fake_related(id : String, ucid : String = "UC_default", views : String = "100") : Hash(String, String)
  {
    "id"               => id,
    "title"            => "Title for #{id}",
    "author"           => "Author",
    "ucid"             => ucid,
    "length_seconds"   => "120",
    "short_view_count" => views,
    "author_verified"  => "false",
    "published"        => "",
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

  it "gives a subscribed channel's candidate a bump over an equally-suggested one" do
    related_lists = [
      [fake_related("from_subscribed", ucid: "UC_subscribed"), fake_related("from_other", ucid: "UC_other")],
    ]

    videos, _has_more = rank_recommendations(related_lists, [] of String, ["UC_subscribed"])

    expect(videos.map(&.id)).to eq(["from_subscribed", "from_other"])
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
