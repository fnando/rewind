# frozen_string_literal: true

require "test_helper"

class StatsTest < Minitest::Test
  def setup
    @user = create_user
    @drama = create_item(media_type: "movie", title: "Drama", runtime: 120,
      metadata_json: {"genres" => [{"name" => "Drama"}],
                      "credits" => {"crew" => [{"job" => "Director", "name" => "Nolan"}], "cast" => []}}.to_json)
    @comedy = create_item(media_type: "movie", title: "Comedy", runtime: 90,
      metadata_json: {"genres" => [{"name" => "Comedy"}]}.to_json)

    Rewind::Play.create(user_id: @user.id, item_id: @drama.id, played_at: Time.now - 86_400, source: "manual")
    Rewind::Play.create(user_id: @user.id, item_id: @drama.id, played_at: Time.now - (2 * 86_400), source: "manual")
    Rewind::Play.create(user_id: @user.id, item_id: @comedy.id, played_at: Time.now - (3 * 86_400), source: "manual")
  end

  test "totals aggregates plays, unique titles, hours, rewatches" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil).to_h
    assert_equal 3, stats[:totals][:plays]
    assert_equal 2, stats[:totals][:unique_titles]
    assert_in_delta 5.5, stats[:totals][:hours_watched], 0.1
    assert_equal 1, stats[:totals][:rewatches]
  end

  test "by_genre sorts descending" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil).to_h
    assert_equal [["Drama", 2], ["Comedy", 1]], stats[:by_genre]
  end

  test "top directors from credits" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil).to_h
    assert_equal [["Nolan", 2]], stats[:top_people][:directors]
  end

  test "respects media_type filter" do
    tv_show = create_item(media_type: "episode", parent_tmdb_id: 1, season_number: 1, episode_number: 1,
                          title: "Ep", runtime: 30)
    Rewind::Play.create(user_id: @user.id, item_id: tv_show.id, played_at: Time.now, source: "manual")

    stats = Rewind::Services::Stats.new(user: @user, media_type: "movie", from: nil, to: nil).to_h
    assert_equal 3, stats[:totals][:plays]

    stats = Rewind::Services::Stats.new(user: @user, media_type: "tv", from: nil, to: nil).to_h
    assert_equal 1, stats[:totals][:plays]
  end
end
