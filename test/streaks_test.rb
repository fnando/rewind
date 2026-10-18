# frozen_string_literal: true

require "test_helper"
require "time"

class StreaksTest < Minitest::Test
  def setup
    @user = create_user
  end

  # Create a play on a given local-UTC date. Defaults keep the time mid-day so
  # it lands on the same calendar day in UTC (the default user time zone).
  def play_on(date, media_type: "movie", at: "12:00:00", user: @user,
              source: "manual", **extra)
    item = create_item(media_type:)
    Rewind::Play.create(
      user_id: user.id, item_id: item.id,
      played_at: Time.parse("#{date} #{at} UTC"), source:, **extra
    )
  end

  def streaks(user: @user, today: nil)
    Rewind::Services::Streaks.new(user:).get_streaks(today:)
  end

  def activity_count(media_group, day, user: @user)
    Rewind.db[:user_day_activity]
          .where(user_id: user.id, media_group:, day:)
          .get(:play_count)
  end

  # --- Streak logic --------------------------------------------------------

  test "no plays yields a zero overall streak and empty groups" do
    result = streaks

    assert_equal 0, result[:overall][:current]
    assert_nil result[:overall][:longest]
    assert_equal %w[movie series music], result[:by_media_group].keys
    assert_equal 0, result[:by_media_group]["movie"][:current]
    assert_nil result[:by_media_group]["movie"][:longest]
  end

  test "a single play today is a current streak of one" do
    play_on("2026-10-18")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 1, result[:overall][:current]
    assert_equal 1, result[:overall][:longest][:length]
    assert result[:overall][:is_record]
    assert_equal 1, result[:by_media_group]["movie"][:current]
  end

  test "a play only yesterday keeps the streak alive" do
    play_on("2026-10-17")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 1, result[:overall][:current]
  end

  test "a play two days ago is a broken streak but keeps the longest" do
    play_on("2026-10-16")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 0, result[:overall][:current]
    assert_equal 1, result[:overall][:longest][:length]
  end

  test "multiple plays on one day count as a single streak day" do
    play_on("2026-10-18")
    play_on("2026-10-18")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 1, result[:overall][:current]
    assert_equal 1, result[:overall][:longest][:length]
    assert_equal 2, activity_count("movie", "2026-10-18")
  end

  test "a gap splits runs and the longest is chosen" do
    play_on("2026-10-10")
    play_on("2026-10-11")
    play_on("2026-10-12")
    play_on("2026-10-18")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 1, result[:overall][:current]
    assert_equal 3, result[:overall][:longest][:length]
    assert_equal "2026-10-10", result[:overall][:longest][:start]
    assert_equal "2026-10-12", result[:overall][:longest][:end]
  end

  test "a day with a movie and an episode counts once overall and per group" do
    play_on("2026-10-18", media_type: "movie")
    play_on("2026-10-18", media_type: "episode")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 1, result[:overall][:longest][:length]
    assert_equal 1, result[:by_media_group]["movie"][:current]
    assert_equal 1, result[:by_media_group]["series"][:current]
  end

  test "alternating types give a long overall run with short group runs" do
    play_on("2026-10-16", media_type: "movie")
    play_on("2026-10-17", media_type: "episode")
    play_on("2026-10-18", media_type: "movie")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 3, result[:overall][:current]
    assert_equal 1, result[:by_media_group]["movie"][:current]
    assert_equal 1, result[:by_media_group]["series"][:current]
  end

  test "a group last played days ago has no current streak but keeps longest" do
    play_on("2026-10-13", media_type: "movie")
    play_on("2026-10-14", media_type: "movie")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 0, result[:by_media_group]["movie"][:current]
    assert_equal 2, result[:by_media_group]["movie"][:longest][:length]
  end

  test "is_record is false when the current run is shorter than the longest" do
    play_on("2026-09-01")
    play_on("2026-09-02")
    play_on("2026-09-03")
    play_on("2026-10-18")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 1, result[:overall][:current]
    assert_equal 3, result[:overall][:longest][:length]
    refute result[:overall][:is_record]
  end

  test "an active streak exposes its current range and strip" do
    play_on("2026-10-17")
    play_on("2026-10-18")

    scope = streaks(today: Date.new(2026, 10, 18))[:overall]
    strip = scope[:strip]

    assert_equal "2026-10-17", scope[:current_range][:start]
    assert_equal "2026-10-18", scope[:current_range][:end]
    assert_equal 14, strip.size
    assert strip.last[:today]
    assert strip.last[:in_streak]
    assert strip[-2][:in_streak]
    refute strip.first[:watched]
  end

  test "a record streak exposes the previous best" do
    %w[2026-09-01 2026-09-02 2026-09-03].each {|d| play_on(d) }
    %w[2026-10-14 2026-10-15 2026-10-16 2026-10-17 2026-10-18].each do |d|
      play_on(d)
    end

    scope = streaks(today: Date.new(2026, 10, 18))[:overall]

    assert scope[:is_record]
    assert_equal 5, scope[:current]
    assert_equal 3, scope[:previous_best][:length]
    assert_equal "2026-09-01", scope[:previous_best][:start]
  end

  test "an ended streak exposes the last run and highlights it in the strip" do
    %w[2026-10-08 2026-10-09 2026-10-10].each {|d| play_on(d) }

    scope = streaks(today: Date.new(2026, 10, 18))[:overall]

    assert_equal 0, scope[:current]
    assert_nil scope[:current_range]
    assert_equal 3, scope[:last_streak][:length]
    assert_equal "2026-10-10", scope[:last_streak][:end]
    highlighted = scope[:strip].count {|cell| cell[:in_streak] }

    assert_equal 3, highlighted
  end

  test "music tracks form their own group" do
    play_on("2026-10-17", media_type: "track")
    play_on("2026-10-18", media_type: "track")

    result = streaks(today: Date.new(2026, 10, 18))

    assert_equal 2, result[:by_media_group]["music"][:current]
  end

  # --- Hooks / sync --------------------------------------------------------

  # The hook fires once per *inserted* row and never for an insert the DB
  # rejects, so activity stays exactly in step with plays (verify is clean)
  # whether or not a re-sync was deduplicated.
  test "re-recording a source event keeps activity consistent with plays" do
    source = create_source(user_id: @user.id)
    item = create_item(media_type: "movie")
    attrs = {
      user_id: @user.id, item_id: item.id, source_id: source.id,
      source: "jellyfin", source_event_id: "evt-1",
      played_at: Time.parse("2026-10-18 12:00:00 UTC")
    }

    2.times do
      Rewind::Play.create(attrs)
    rescue Sequel::UniqueConstraintViolation
      nil
    end

    play_rows = Rewind::Play.where(user_id: @user.id).count

    assert_equal play_rows, activity_count("movie", "2026-10-18")
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "deleting one of two same-day plays keeps the day; last removes it" do
    first = play_on("2026-10-18")
    play_on("2026-10-18")

    first.destroy

    assert_equal 1, activity_count("movie", "2026-10-18")

    Rewind::Play.where(user_id: @user.id).last.destroy

    assert_nil activity_count("movie", "2026-10-18")
  end

  test "a dateless play never touches the activity table" do
    item = create_item(media_type: "movie")
    Rewind::Play.create(user_id: @user.id, item_id: item.id,
                        played_at: nil, source: "jellyfin")

    assert_equal 0, Rewind.db[:user_day_activity].where(user_id: @user.id).count
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "moving a play to another day moves the activity" do
    play = play_on("2026-10-18")

    play.update(played_at: Time.parse("2026-10-10 12:00:00 UTC"))

    assert_nil activity_count("movie", "2026-10-18")
    assert_equal 1, activity_count("movie", "2026-10-10")
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "verify reports no differences after a mix of writes and deletes" do
    play_on("2026-10-16", media_type: "movie")
    play_on("2026-10-17", media_type: "episode")
    extra = play_on("2026-10-17", media_type: "track")
    play_on("2026-10-18", media_type: "track")
    extra.destroy

    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  # --- Rebuild -------------------------------------------------------------

  test "rebuild_user reconstructs the table from plays" do
    play_on("2026-10-17")
    play_on("2026-10-18")
    Rewind.db[:user_day_activity].where(user_id: @user.id).delete

    Rewind::Services::Streaks.rebuild_user(@user)

    assert_empty Rewind::Services::Streaks.verify(@user)
    assert_equal 1, activity_count("movie", "2026-10-18")
  end

  # --- Stats page ----------------------------------------------------------

  test "the stats page shows the streak card for an active streak" do
    item = create_item(media_type: "movie")
    [Time.now, Time.now - 86_400].each do |played_at|
      Rewind::Play.create(user_id: @user.id, item_id: item.id,
                          played_at:, source: "manual")
    end
    sign_in(@user)

    get "/stats?period=all&type=all"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "streak-card"
    assert_includes last_response.body, "in a row"
    assert_includes last_response.body, "Longest streak:"
  end

  test "the stats page renders the record state end to end" do
    item = create_item(media_type: "movie")
    # A 3-day current streak (today back) plus a shorter older streak.
    [0, 1, 2, 30].each do |days_ago|
      Rewind::Play.create(user_id: @user.id, item_id: item.id,
                          played_at: Time.now - (days_ago * 86_400),
                          source: "manual")
    end
    sign_in(@user)

    get "/stats?period=all&type=all"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "New record"
    assert_includes last_response.body, "Previous best:"
  end

  test "the stats page renders the ended state end to end" do
    item = create_item(media_type: "movie")
    # A 3-day streak that ended several days ago; nothing today or yesterday.
    [5, 6, 7].each do |days_ago|
      Rewind::Play.create(user_id: @user.id, item_id: item.id,
                          played_at: Time.now - (days_ago * 86_400),
                          source: "manual")
    end
    sign_in(@user)

    get "/stats?period=all&type=all"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "streak-card--idle"
    assert_includes last_response.body, "chase it"
  end

  test "the stats page shows the first-time streak card with a CTA" do
    create_item(media_type: "movie") # item but no plays
    sign_in(@user)

    get "/stats?period=all&type=all"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "No streak yet"
    assert_includes last_response.body, "Log a watch"
  end

  # --- Dates / time zones --------------------------------------------------

  test "a late-night play lands on the local day, not the UTC day" do
    user = create_user(username: "vancouver")
    user.update(timezone: "America/Vancouver")
    # 06:30 UTC is 23:30 the previous day in Vancouver.
    play_on("2026-10-18", at: "06:30:00", user:)

    assert_equal 1, activity_count("movie", "2026-10-17", user:)
    assert_nil activity_count("movie", "2026-10-18", user:)
  end

  test "changing a user's time zone and rebuilding regroups their days" do
    play_on("2026-10-18", at: "06:30:00")

    assert_equal 1, activity_count("movie", "2026-10-18")

    @user.update(timezone: "America/Vancouver")
    Rewind::Services::Streaks.rebuild_user(@user)

    assert_nil activity_count("movie", "2026-10-18")
    assert_equal 1, activity_count("movie", "2026-10-17")
    assert_empty Rewind::Services::Streaks.verify(@user)
  end
end
