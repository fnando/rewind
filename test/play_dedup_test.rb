# frozen_string_literal: true

require "test_helper"

class PlayDedupTest < Minitest::Test
  def setup
    @user = create_user
    @source = create_source(user_id: @user.id)
    @track = create_item(media_type: "track", title: "Rosemead",
                         external_id: "mbid:t1",
                         metadata_json: {"length_ms" => 180_000}.to_json)
    @start = Time.parse("2026-10-19T21:00:00Z")
  end

  def pull_play(played_at, event)
    Rewind::Play.create(
      user_id: @user.id, item_id: @track.id, source: "jellyfin",
      source_id: @source.id, instance_id: @source.instance_id,
      source_event_id: event, played_at:
    )
  end

  def webhook_play(played_at, event)
    Rewind::Play.create(
      user_id: @user.id, item_id: @track.id, source: "jellyfin",
      source_id: nil, instance_id: @source.instance_id,
      source_event_id: event, played_at:
    )
  end

  def play_ids
    Rewind::Play.where(item_id: @track.id).select_map(:id)
  end

  test "it collapses a pull-start / webhook-stop pair, keeping the pull row" do
    kept = pull_play(@start, "jellyfin:t1:start")
    webhook_play(@start + 180, "jellyfin:t1:stop") # one runtime later

    assert_equal 1, Rewind::Services::PlayDedup.run
    assert_equal [kept.id], play_ids
  end

  test "it leaves a webhook-only play (no pull partner) alone" do
    webhook_play(@start, "jellyfin:t1:stop")

    assert_equal 0, Rewind::Services::PlayDedup.run
    assert_equal 1, Rewind::Play.where(item_id: @track.id).count
  end

  test "it keeps a webhook play beyond one runtime (a distinct listen)" do
    pull_play(@start, "jellyfin:t1:start")
    webhook_play(@start + 1000, "jellyfin:t1:stop2") # well past the runtime

    assert_equal 0, Rewind::Services::PlayDedup.run
    assert_equal 2, Rewind::Play.where(item_id: @track.id).count
  end

  test "it is idempotent" do
    pull_play(@start, "jellyfin:t1:start")
    webhook_play(@start + 180, "jellyfin:t1:stop")

    assert_equal 1, Rewind::Services::PlayDedup.run
    assert_equal 0, Rewind::Services::PlayDedup.run
  end

  test "it realigns user_day_activity for the dropped play" do
    pull_play(@start, "jellyfin:t1:start")
    webhook_play(@start + 180, "jellyfin:t1:stop")

    Rewind::Services::PlayDedup.run

    activity = Rewind.db[:user_day_activity]
                     .where(user_id: @user.id, media_group: "music")
                     .sum(:play_count)

    assert_equal 1, activity
  end

  # A 45-minute episode re-logged every minute as it played.
  def episode_setup
    @episode = create_item(media_type: "episode", title: "Ludwig",
                           external_id: "tmdb:ep1", runtime: 45)
  end

  def episode_play(played_at)
    Rewind::Play.create(
      user_id: @user.id, item_id: @episode.id, source: "jellyfin",
      source_id: @source.id, instance_id: @source.instance_id,
      source_event_id: "jellyfin:ep1:#{played_at.iso8601}", played_at:
    )
  end

  test "it collapses a video re-logged across one watch to the earliest play" do
    episode_setup
    kept = episode_play(@start)
    3.times {|i| episode_play(@start + ((i + 1) * 60)) } # +1, +2, +3 minutes

    assert_equal 3, Rewind::Services::PlayDedup.run
    assert_equal [kept.id], Rewind::Play.where(item_id: @episode.id)
                                        .select_map(:id)
  end

  test "it keeps a genuine re-watch well beyond the runtime window" do
    episode_setup
    episode_play(@start)
    episode_play(@start + (60 * 60)) # an hour later — past the ~47-min window

    assert_equal 0, Rewind::Services::PlayDedup.run
    assert_equal 2, Rewind::Play.where(item_id: @episode.id).count
  end

  test "the video sweep is idempotent" do
    episode_setup
    episode_play(@start)
    episode_play(@start + 60)

    assert_equal 1, Rewind::Services::PlayDedup.run
    assert_equal 0, Rewind::Services::PlayDedup.run
  end

  test "it does not collapse repeated audio plays (legitimate replays)" do
    pull_play(@start, "jellyfin:t1:a")
    pull_play(@start + 60, "jellyfin:t1:b") # same track again, no webhook

    assert_equal 0, Rewind::Services::PlayDedup.run
    assert_equal 2, Rewind::Play.where(item_id: @track.id).count
  end
end
