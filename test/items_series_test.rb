# frozen_string_literal: true

require "test_helper"

class GenericSeriesPageTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)
    @series = create_item(
      media_type: "series", external_id: "jellyfin:s1",
      title: "Porta dos Fundos",
      metadata_json: {"source" => "jellyfin"}.to_json
    )
    @episode = create_item(
      media_type: "episode", external_id: "youtube:v1",
      parent_external_id: "jellyfin:s1", title: "Sketch",
      season_number: 2026, episode_number: 70_198, release_date: "2026-07-01",
      metadata_json: {"source" => "jellyfin"}.to_json
    )
    Rewind::Play.create(user_id: @user.id, item_id: @episode.id,
                        played_at: Time.now, source: "jellyfin")
  end

  test "a Jellyfin series lists its real episodes, not faked seasons" do
    get "/items/#{@series.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "1 episode watched"
    assert_includes last_response.body, "Sketch"
    # no synthesized "Season 1 / 10 episodes" placeholders
    refute_includes last_response.body, "Mark watched"
    refute_includes last_response.body, " of 10 "
  end
end
