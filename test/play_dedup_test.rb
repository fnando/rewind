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
end
