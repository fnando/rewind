# frozen_string_literal: true

require "test_helper"

class HistoryTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)
  end

  def create_plays(count, media_type: "movie")
    base = Time.now
    Array.new(count) do |i|
      item = create_item(media_type:, title: "Item #{i}")
      Rewind::Play.create(user_id: @user.id, item_id: item.id,
                          played_at: base - i, source: "manual")
    end
  end

  test "a dateless play renders as 'Watched' under an undated group" do
    item = create_item(media_type: "movie", title: "Adventure Time")
    Rewind::Play.create(user_id: @user.id, item_id: item.id,
                        played_at: nil, source: "jellyfin")

    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Adventure Time"
    assert_includes last_response.body, "date unknown"
    assert_includes last_response.body, "Watched · Jellyfin"
  end

  test "no pagination nav when plays fit on one page" do
    create_plays(3)

    get "/history"

    assert_equal 200, last_response.status
    refute_includes last_response.body, "pagination"
  end

  test "first page shows Older link but no Newer link" do
    create_plays(Rewind::Application::PLAYS_PER_PAGE + 1)

    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, ">Older</a>"
    refute_includes last_response.body, ">Newer</a>"
    assert_includes last_response.body, %[href="/history?page=2"]
  end

  test "second page shows Newer link and the oldest play" do
    plays = create_plays(Rewind::Application::PLAYS_PER_PAGE + 1)
    oldest = plays.last

    get "/history?page=2"

    assert_equal 200, last_response.status
    assert_includes last_response.body, ">Newer</a>"
    refute_includes last_response.body, ">Older</a>"
    assert_includes last_response.body, %[href="/items/#{oldest.item_id}"]
  end

  test "pagination preserves the media type filter" do
    create_plays(Rewind::Application::PLAYS_PER_PAGE + 1, media_type: "track")

    get "/history?type=track"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "type=track"
    assert_includes last_response.body, "page=2"
  end

  test "a movie renders as a portrait cover card" do
    item = create_item(media_type: "movie", title: "Whiplash",
                       release_date: "2014-10-10")
    Rewind::Play.create(user_id: @user.id, item_id: item.id,
                        played_at: Time.now, source: "jellyfin")

    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "cover-card cover-card--movie"
    assert_includes last_response.body, ">Movie</span>"
    assert_includes last_response.body,
                    %[<a class="cover-card__title" href="/items/#{item.id}">]
    assert_includes last_response.body, "2014"
    assert_includes last_response.body, "Jellyfin"
  end

  test "a track renders as a square cover card" do
    item = create_item(media_type: "track", title: "Maps",
                       metadata_json: {
                         "artist" => "Yeah Yeah Yeahs",
                         "album" => "Fever to Tell"
                       }.to_json)
    Rewind::Play.create(user_id: @user.id, item_id: item.id,
                        played_at: Time.now, source: "jellyfin")

    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "cover-card cover-card--track"
    assert_includes last_response.body, ">Track</span>"
    assert_includes last_response.body, "Yeah Yeah Yeahs · Fever to Tell"
  end

  test "an episode titles the episode and puts the show in the detail" do
    show = create_item(media_type: "series", title: "Ludwig",
                       external_id: "tmdb:9001")
    episode = create_item(media_type: "episode", title: "Pilot",
                          external_id: "tmdb:9002",
                          parent_external_id: "tmdb:9001",
                          season_number: 1, episode_number: 2,
                          metadata_json: {"series_name" => "Ludwig"}.to_json)
    Rewind::Play.create(user_id: @user.id, item_id: episode.id,
                        played_at: Time.now, source: "manual")

    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, ">Episode</span>"
    title_link =
      %[<a class="cover-card__title" href="/items/#{episode.id}">Pilot</a>]

    assert_includes last_response.body, title_link
    # The detail reads "S1 · E2 — <linked show name>".
    assert_includes last_response.body, "S1 · E2 — "
    assert_includes last_response.body, %[href="/items/#{show.id}">Ludwig</a>]
  end

  test "a cover-less item falls back to the styled poster placeholder" do
    item = create_item(media_type: "movie", title: "No Art", external_id: "")
    Rewind::Play.create(user_id: @user.id, item_id: item.id,
                        played_at: Time.now, source: "manual")

    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "/poster-placeholder.svg"
    assert_includes last_response.body, "cover-card__img--placeholder"
  end

  test "the rating control is rendered on the cover" do
    item = create_item(media_type: "movie", title: "Rated")
    Rewind::Play.create(user_id: @user.id, item_id: item.id,
                        played_at: Time.now, source: "manual")

    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "on-cover"
  end
end
