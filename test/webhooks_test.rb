# frozen_string_literal: true

require "test_helper"

class WebhooksTest < Minitest::Test
  SERVER_ID = "a73ef832a7b240ed872bd9eaca9e4e2f"
  JELLYFIN_USER = "9321f0b17ae7471fadeceb9cbabe4109"
  TRACK_JF_ID = "c7fc103dee9e755baacadd144a5ded90"

  def setup
    @user = create_user
    create_source(user_id: @user.id, external_user_id: JELLYFIN_USER,
                  instance_id: SERVER_ID)
    # Pre-synced track, so the webhook resolves by jellyfin_id (no network).
    @track = create_item(media_type: "track", title: "Rosemead",
                         jellyfin_id: TRACK_JF_ID)
    _, @secret = Rewind::Webhook.mint(name: "mediabox")
  end

  def payload(overrides = {})
    {
      "NotificationType" => "PlaybackStop",
      "ItemType" => "Audio",
      "PlayedToCompletion" => true,
      "ServerId" => SERVER_ID,
      "UserId" => JELLYFIN_USER,
      "ItemId" => TRACK_JF_ID,
      "Name" => "Rosemead",
      "UtcTimestamp" => "2026-10-19T21:09:23.8576697Z"
    }.merge(overrides)
  end

  def post_webhook(body, secret: @secret)
    post "/webhooks/jellyfin/#{secret}", body.to_json,
         {"CONTENT_TYPE" => "application/json"}
  end

  def plays_for_track
    Rewind::Play.where(user_id: @user.id, item_id: @track.id)
  end

  test "a completed audio playback records a play" do
    post_webhook(payload)

    assert_equal 204, last_response.status
    assert_equal 1, plays_for_track.count
    play = plays_for_track.first

    assert_equal "jellyfin", play.source
    assert_equal SERVER_ID, play.instance_id
    assert_in_delta Time.parse("2026-10-19T21:09:23.8576697Z").to_f,
                    play.played_at.to_f, 0.01
  end

  test "a bad secret is rejected and records nothing" do
    post_webhook(payload, secret: "nope")

    assert_equal 401, last_response.status
    assert_equal 0, plays_for_track.count
  end

  test "an incomplete playback is ignored" do
    post_webhook(payload("PlayedToCompletion" => false))

    assert_equal 204, last_response.status
    assert_equal 0, plays_for_track.count
  end

  test "a non-audio event is ignored" do
    post_webhook(payload("ItemType" => "Movie"))

    assert_equal 0, plays_for_track.count
  end

  test "a re-delivered event does not double-record" do
    2.times { post_webhook(payload) }

    assert_equal 1, plays_for_track.count
  end

  test "it dedups against a pull play of the same track near the same time" do
    # Pull already recorded this completion a second earlier.
    Rewind::Play.create(
      user_id: @user.id, item_id: @track.id, source: "jellyfin",
      instance_id: SERVER_ID,
      source_event_id: "jellyfin:#{TRACK_JF_ID}:2026-10-19T21:09:22Z",
      played_at: Time.parse("2026-10-19T21:09:22Z")
    )

    post_webhook(payload) # ~1s later

    assert_equal 1, plays_for_track.count # merged, not doubled
  end

  test "a genuine re-listen outside the window is kept" do
    post_webhook(payload)
    post_webhook(payload("UtcTimestamp" => "2026-10-19T21:15:00Z"))

    assert_equal 2, plays_for_track.count
  end

  test "an unknown Jellyfin user is skipped" do
    post_webhook(payload("UserId" => "someone-else"))

    assert_equal 204, last_response.status
    assert_equal 0, plays_for_track.count
  end

  test "a later pull of a webhook-settled play does not duplicate it" do
    # Webhook settles the play first (the common case: pull runs each minute).
    post_webhook(payload)

    assert_equal 1, plays_for_track.count

    # Pull then sees the same completion under its own source_event_id.
    source = Rewind::Source.where(user_id: @user.id, type: "jellyfin").first
    Rewind::Services::Sync.record_play(
      source,
      item_id: @track.id,
      source_event_id: "jellyfin:#{TRACK_JF_ID}:2026-10-19T21:09:24Z",
      played_at: Time.parse("2026-10-19T21:09:24Z") # ~1s after the webhook
    )

    assert_equal 1, plays_for_track.count # pull skipped the duplicate
  end
end
