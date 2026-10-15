# frozen_string_literal: true

require "test_helper"

class StatsTest < Minitest::Test
  def setup
    @user = create_user
    @drama = create_item(
      media_type: "movie", title: "Drama", runtime: 120,
      metadata_json: {
        "genres" => [{"name" => "Drama"}],
        "credits" => {"crew" => [{"job" => "Director", "name" => "Nolan"}], "cast" => [{"name" => "DiCaprio"}]}
      }.to_json
    )
    @comedy = create_item(
      media_type: "movie", title: "Comedy", runtime: 90,
      metadata_json: {"genres" => [{"name" => "Comedy"}]}.to_json
    )

    Rewind::Play.create(user_id: @user.id, item_id: @drama.id, played_at: Time.now - 86_400, source: "manual")
    Rewind::Play.create(user_id: @user.id, item_id: @drama.id, played_at: Time.now - (2 * 86_400), source: "manual")
    Rewind::Play.create(user_id: @user.id, item_id: @comedy.id, played_at: Time.now - (3 * 86_400), source: "manual")
  end

  test "totals aggregates plays, unique titles, movies/episodes split, hours, rewatches" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil, period: "all").to_h
    totals = stats[:totals]
    assert_equal 3, totals[:plays]
    assert_equal 2, totals[:unique_titles]
    assert_equal 3, totals[:movies_count]
    assert_equal 0, totals[:episodes_count]
    assert_in_delta 5.5, totals[:hours_watched], 0.1
    assert_equal 1, totals[:rewatches]
  end

  test "headline formats days + hours sentence" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil, period: "all").to_h
    assert_match(/\A\d+ hours in front of the screen/, stats[:headline][:hours_sentence])
    assert_equal 3, stats[:headline][:big_number]
  end

  test "top_genres sorts descending" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil, period: "all").to_h
    assert_equal [{name: "Drama", count: 2}, {name: "Comedy", count: 1}],
                 stats[:top_genres].map {|g| g.slice(:name, :count) }
  end

  test "top_directors from credits includes top item title" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil, period: "all").to_h
    nolan = stats[:top_directors].first
    assert_equal "Nolan", nolan[:name]
    assert_equal 2, nolan[:count]
    assert_equal "Drama", nolan[:top_item_title]
  end

  test "top_cast includes top item title" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil, period: "all").to_h
    leo = stats[:top_cast].first
    assert_equal "DiCaprio", leo[:name]
    assert_equal "Drama", leo[:top_item_title]
  end

  test "respects media_type filter" do
    tv_item = create_item(media_type: "episode", parent_tmdb_id: 1, season_number: 1, episode_number: 1,
                          title: "Ep", runtime: 30)
    Rewind::Play.create(user_id: @user.id, item_id: tv_item.id, played_at: Time.now, source: "manual")

    stats = Rewind::Services::Stats.new(user: @user, media_type: "movie", from: nil, to: nil, period: "all").to_h
    assert_equal 3, stats[:totals][:plays]

    stats = Rewind::Services::Stats.new(user: @user, media_type: "tv", from: nil, to: nil, period: "all").to_h
    assert_equal 1, stats[:totals][:plays]
  end

  test "rhythm for year period has 12 monthly buckets" do
    from, to = Rewind::Services::Stats.resolve_period("year")
    stats = Rewind::Services::Stats.new(user: @user, from: from, to: to, period: "year").to_h
    assert_equal 12, stats[:rhythm].size
    assert stats[:rhythm].all? {|r| r.key?(:movies) && r.key?(:episodes) && r.key?(:total) && r.key?(:peak) }
  end

  test "heatmap exposes biggest day" do
    from, to = Rewind::Services::Stats.resolve_period("year")
    stats = Rewind::Services::Stats.new(user: @user, from: from, to: to, period: "year").to_h
    refute_nil stats[:heatmap]
    assert_operator stats[:heatmap][:days_with_plays], :>=, 1
    refute_nil stats[:heatmap][:biggest_day]
  end

  test "top_shows groups episode plays by parent" do
    tv_item = create_item(
      media_type: "episode", parent_tmdb_id: 99, season_number: 1, episode_number: 1,
      title: "Pilot", runtime: 42,
      metadata_json: {"series_name" => "Lost"}.to_json
    )
    Rewind::Play.create(user_id: @user.id, item_id: tv_item.id, played_at: Time.now, source: "manual")

    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil, period: "all").to_h
    row = stats[:top_shows].first
    assert_equal "Lost", row[:name]
    assert_equal 1, row[:episode_count]
  end
end
