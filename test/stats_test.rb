# frozen_string_literal: true

require "test_helper"

class StatsTest < Minitest::Test
  def setup
    @user = create_user
    @drama = create_item(
      media_type: "movie", title: "Drama", runtime: 120,
      metadata_json: {
        "genres" => [{"name" => "Drama"}],
        "credits" => {
          "crew" => [{"job" => "Director", "name" => "Nolan"}],
          "cast" => [{"name" => "DiCaprio"}]
        }
      }.to_json
    )
    @comedy = create_item(
      media_type: "movie", title: "Comedy", runtime: 90,
      metadata_json: {"genres" => [{"name" => "Comedy"}]}.to_json
    )

    Rewind::Play.create(user_id: @user.id, item_id: @drama.id,
                        played_at: Time.now - 86_400, source: "manual")
    Rewind::Play.create(user_id: @user.id, item_id: @drama.id,
                        played_at: Time.now - (2 * 86_400), source: "manual")
    Rewind::Play.create(user_id: @user.id, item_id: @comedy.id,
                        played_at: Time.now - (3 * 86_400), source: "manual")
  end

  test "totals aggregates plays, titles, media split, hours, rewatches" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "all").to_h
    totals = stats[:totals]

    assert_equal 3, totals[:plays]
    assert_equal 2, totals[:unique_titles]
    assert_equal 3, totals[:movies_count]
    assert_equal 0, totals[:episodes_count]
    assert_in_delta 5.5, totals[:hours_watched], 0.1
    assert_equal 1, totals[:rewatches]
  end

  test "the hero reads as a sentence about screen time" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "all").to_h

    assert_equal "6 hours in front of the screen, start to finish.",
                 stats[:headline][:hours_sentence]
    assert_equal 3, stats[:headline][:big_number]
  end

  test "the hero combines video and audio for a mixed view" do
    track = create_item(media_type: "track", external_id: "mbid:z",
                        title: "Long One", runtime: 90)
    Rewind::Play.create(user_id: @user.id, item_id: track.id,
                        played_at: Time.now, source: "jellyfin")
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "year").to_h

    assert_equal "6 hours in front of the screen and 2 hours of music.",
                 stats[:headline][:hours_sentence]
  end

  test "rhythm bucket tooltips label the bucket and break down hours" do
    busiest = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                          period: "all").to_h[:rhythm]
                                     .max_by {|r| r[:total] }

    assert_match(/\A.+ • \d+ hours? of video/, busiest[:tooltip])
  end

  test "top_genres sorts descending" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "all").to_h

    assert_equal([{name: "Drama", count: 2}, {name: "Comedy", count: 1}],
                 stats[:top_genres].map {|g| g.slice(:name, :count) })
  end

  test "top_directors from credits includes top item title" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "all").to_h
    nolan = stats[:top_directors].first

    assert_equal "Nolan", nolan[:name]
    assert_equal 2, nolan[:count]
    assert_equal "Drama", nolan[:top_item_title]
  end

  test "top_cast includes top item title" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "all").to_h
    leo = stats[:top_cast].first

    assert_equal "DiCaprio", leo[:name]
    assert_equal "Drama", leo[:top_item_title]
  end

  test "respects media_type filter" do
    tv_item = create_item(media_type: "episode", parent_external_id: "tmdb:1",
                          season_number: 1, episode_number: 1,
                          title: "Ep", runtime: 30)
    Rewind::Play.create(user_id: @user.id, item_id: tv_item.id,
                        played_at: Time.now, source: "manual")

    stats = Rewind::Services::Stats.new(user: @user, media_type: "movie",
                                        from: nil, to: nil, period: "all").to_h

    assert_equal 3, stats[:totals][:plays]

    stats = Rewind::Services::Stats.new(user: @user, media_type: "series",
                                        from: nil, to: nil, period: "all").to_h

    assert_equal 1, stats[:totals][:plays]
  end

  test "rhythm for year period has 12 monthly buckets" do
    from, to = Rewind::Services::Stats.resolve_period("year")
    stats = Rewind::Services::Stats.new(user: @user, from: from, to: to,
                                        period: "year").to_h

    assert_equal 12, stats[:rhythm].size
    assert(stats[:rhythm].all? do |r|
      r.key?(:movies) && r.key?(:episodes) && r.key?(:total) && r.key?(:peak)
    end)
  end

  test "heatmap exposes biggest day" do
    from, to = Rewind::Services::Stats.resolve_period("year")
    stats = Rewind::Services::Stats.new(user: @user, from: from, to: to,
                                        period: "year").to_h

    refute_nil stats[:heatmap]
    assert_operator stats[:heatmap][:days_with_plays], :>=, 1
    refute_nil stats[:heatmap][:biggest_day]
  end

  test "top_shows groups episode plays by parent" do
    tv_item = create_item(
      media_type: "episode", parent_external_id: "tmdb:99",
      season_number: 1, episode_number: 1,
      title: "Pilot", runtime: 42,
      metadata_json: {"series_name" => "Lost"}.to_json
    )
    Rewind::Play.create(user_id: @user.id, item_id: tv_item.id,
                        played_at: Time.now, source: "manual")

    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "all").to_h
    row = stats[:top_shows].first

    assert_equal "Lost", row[:name]
    assert_equal 1, row[:episode_count]
  end

  def seed_music
    @artist = create_item(media_type: "artist",
                          external_id: "mbid:artist:a1", title: "Radiohead")
    @album = create_item(
      media_type: "album", external_id: "mbid:rg:r1", title: "OK Computer",
      parent_external_id: "mbid:artist:a1", poster_path: "https://art/r1.jpg"
    )
    @track = create_item(
      media_type: "track", external_id: "mbid:t1", title: "Karma Police",
      parent_external_id: "mbid:rg:r1", runtime: 4,
      metadata_json: {
        "artist" => "Radiohead", "artist_external_id" => "mbid:artist:a1",
        "album" => "OK Computer", "album_external_id" => "mbid:rg:r1"
      }.to_json
    )
    2.times do |n|
      Rewind::Play.create(user_id: @user.id, item_id: @track.id,
                          played_at: Time.now - (n * 3600), source: "jellyfin")
    end
  end

  test "top_artists, top_albums and top_tracks rank music plays" do
    seed_music
    stats = Rewind::Services::Stats.new(user: @user, media_type: "music",
                                        from: nil, to: nil, period: "all").to_h

    assert_equal "Radiohead", stats[:top_artists].first[:name]
    assert_equal 2, stats[:top_artists].first[:count]
    assert_equal "OK Computer", stats[:top_albums].first[:name]
    assert_equal "Karma Police", stats[:top_tracks].first[:item].title
    assert_equal @album.id, stats[:top_tracks].first[:album].id
  end

  test "track runtime does not count as screen time" do
    seed_music
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "all").to_h
    totals = stats[:totals]

    # The three movie plays from setup are 5.5h; the tracks add listening only.
    assert_in_delta 5.5, totals[:hours_watched], 0.1
    assert_operator totals[:listening_hours], :>, 0
    assert_equal 2, totals[:tracks_count]
  end

  test "music headline uses listens, not things watched" do
    seed_music
    stats = Rewind::Services::Stats.new(user: @user, media_type: "music",
                                        from: nil, to: nil, period: "all").to_h

    assert_equal "listens", stats[:headline][:unit]
  end

  test "the all view headline uses the neutral things played" do
    stats = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                        period: "all").to_h

    assert_equal "things played", stats[:headline][:unit]
  end

  test "the movies view headline uses things watched" do
    stats = Rewind::Services::Stats.new(user: @user, media_type: "movie",
                                        from: nil, to: nil, period: "all").to_h

    assert_equal "things watched", stats[:headline][:unit]
  end

  test "the repeats card wording adapts to the media type" do
    movie = Rewind::Services::Stats.new(user: @user, media_type: "movie",
                                        from: nil, to: nil, period: "all").to_h
    music = Rewind::Services::Stats.new(user: @user, media_type: "music",
                                        from: nil, to: nil, period: "all").to_h
    all = Rewind::Services::Stats.new(user: @user, from: nil, to: nil,
                                      period: "all").to_h

    assert_includes movie[:cards][:rewatch_label], "worth seeing twice"
    assert_includes music[:cards][:rewatch_label], "worth a second listen"
    assert_includes all[:cards][:rewatch_label], "worth going back to"
  end

  test "music filter returns only track plays" do
    seed_music
    stats = Rewind::Services::Stats.new(user: @user, media_type: "music",
                                        from: nil, to: nil, period: "all").to_h

    assert_equal 2, stats[:totals][:plays]
    assert_empty stats[:top_movies]
  end
end
