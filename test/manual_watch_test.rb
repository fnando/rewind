# frozen_string_literal: true

require "test_helper"

class ManualWatchTest < Minitest::Test
  def setup
    @user = create_user
    @user.update(timezone: "America/Los_Angeles")
    sign_in(@user)
    @movie = create_item(media_type: "movie", title: "Clayface")
  end

  test "logs a watch at the date and time picked in the user's timezone" do
    post "/history", {item_id: @movie.id, played_at: "2026-10-30T21:15"}

    play = Rewind::Play.last

    # 21:15 PDT (UTC-7) is 04:15 UTC the next day; the day stays the 30th.
    assert_equal Time.utc(2026, 10, 31, 4, 15), play.played_at
    assert_equal "2026-10-30", play.local_date
    assert_equal "manual", play.source
  end

  test "logs a watch now when no time is given" do
    post "/history", {item_id: @movie.id}

    assert_in_delta Time.now, Rewind::Play.last.played_at, 5
  end

  test "rejects a watch in the future" do
    later = Time.now + (3 * 86_400)
    post "/history", {
      item_id: @movie.id,
      played_at: later.strftime("%Y-%m-%dT%H:%M")
    }

    assert_equal 422, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "rejects a value that isn't a date and time" do
    post "/history", {item_id: @movie.id, played_at: "yesterday-ish"}

    assert_equal 400, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "a time skipped by a DST jump rolls forward an hour" do
    # 2026-03-08 02:30 doesn't exist in Los Angeles; it reads as 03:30 PDT.
    assert_equal Time.utc(2026, 3, 8, 10, 30),
                 @user.local_time_to_utc("2026-03-08T02:30")
  end

  test "the movie page offers a date and time defaulting to now" do
    get "/items/#{@movie.id}"

    assert_includes last_response.body, 'type="datetime-local"'
    assert_includes last_response.body, 'name="played_at"'
  end

  test "logs an episode at the picked time" do
    show = create_item(media_type: "series", external_id: "tmdb:1399",
                       title: "Game of Thrones")
    stub_tmdb_tv(1399)
    stub_tmdb_episode(1399, 1, 2)

    post "/items/#{show.id}/log-episode",
         {season: 1, episode: 2, played_at: "2026-10-30T21:15"}

    assert_equal Time.utc(2026, 10, 31, 4, 15), Rewind::Play.last.played_at
  end
end
