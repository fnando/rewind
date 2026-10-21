# frozen_string_literal: true

require "test_helper"

class WebhooksTest < Minitest::Test
  SERVER_ID = "a73ef832a7b240ed872bd9eaca9e4e2f"
  JELLYFIN_USER = "9321f0b17ae7471fadeceb9cbabe4109"
  TRACK_JF_ID = "c7fc103dee9e755baacadd144a5ded90"
  # A track's LastPlayedDate (its start), set before the stop UtcTimestamp.
  LAST_PLAYED = "2026-10-19T21:09:20.1234567Z"

  def setup
    @user = create_user
    @source = create_source(user_id: @user.id, external_user_id: JELLYFIN_USER,
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

  # Stub the item re-fetch that keys the play on its LastPlayedDate. Pass nil to
  # simulate a track Jellyfin never settled a date for.
  def stub_last_played(value = LAST_PLAYED)
    user_data = value ? {"LastPlayedDate" => value} : {}
    WebMock.stub_request(
      :get, "#{@source.url}/Users/#{JELLYFIN_USER}/Items/#{TRACK_JF_ID}"
    ).to_return(status: 200, body: {"UserData" => user_data}.to_json,
                headers: {"Content-Type" => "application/json"})
  end

  def post_webhook(body, secret: @secret)
    post "/webhooks/jellyfin/#{secret}", body.to_json,
         {"CONTENT_TYPE" => "application/json"}
  end

  def plays_for_track
    Rewind::Play.where(user_id: @user.id, item_id: @track.id)
  end

  test "a completed audio playback records a play keyed on LastPlayedDate" do
    stub_last_played

    post_webhook(payload)

    assert_equal 204, last_response.status
    assert_equal 1, plays_for_track.count
    play = plays_for_track.first

    assert_equal "jellyfin", play.source
    assert_equal SERVER_ID, play.instance_id
    assert_equal "jellyfin:#{TRACK_JF_ID}:#{LAST_PLAYED}", play.source_event_id
    assert_in_delta Time.parse(LAST_PLAYED).to_f, play.played_at.to_f, 0.01
  end

  test "it falls back to the stop time when no LastPlayedDate is set" do
    stub_last_played(nil)

    post_webhook(payload)

    assert_equal 1, plays_for_track.count
    play = plays_for_track.first
    stop = "2026-10-19T21:09:23.8576697Z"

    assert_equal "jellyfin:#{TRACK_JF_ID}:#{stop}", play.source_event_id
    assert_in_delta Time.parse(stop).to_f, play.played_at.to_f, 0.01
  end

  test "a bad secret is rejected and records nothing" do
    post_webhook(payload, secret: "nope")

    assert_equal 401, last_response.status
    assert_equal 0, plays_for_track.count
  end

  test "a malformed body is rejected and logged with a snippet" do
    io = StringIO.new
    level = Rewind.logger.level
    Rewind.logger.reopen(io)
    Rewind.logger.level = Logger::WARN

    begin
      post "/webhooks/jellyfin/#{@secret}", '{"Name": broken',
           {"CONTENT_TYPE" => "application/json"}
    ensure
      Rewind.logger.level = level
      Rewind.logger.reopen($stdout)
    end

    assert_equal 400, last_response.status
    assert_includes io.string, "rejected: invalid json"
    assert_includes io.string, "broken" # the body snippet is logged
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
    stub_last_played

    2.times { post_webhook(payload) }

    assert_equal 1, plays_for_track.count
  end

  test "it dedups against a pull play of the same completion" do
    stub_last_played
    # Pull already recorded this completion under the shared LastPlayedDate key.
    Rewind::Play.create(
      user_id: @user.id, item_id: @track.id, source: "jellyfin",
      instance_id: SERVER_ID,
      source_event_id: "jellyfin:#{TRACK_JF_ID}:#{LAST_PLAYED}",
      played_at: Time.parse(LAST_PLAYED)
    )

    post_webhook(payload)

    assert_equal 1, plays_for_track.count # merged, not doubled
  end

  test "two plays with distinct LastPlayedDates are both kept" do
    stub_last_played
    post_webhook(payload)

    stub_last_played("2026-10-19T21:30:00.0000000Z")
    post_webhook(payload("UtcTimestamp" => "2026-10-19T21:33:00Z"))

    assert_equal 2, plays_for_track.count
  end

  test "an unknown Jellyfin user is skipped" do
    post_webhook(payload("UserId" => "someone-else"))

    assert_equal 204, last_response.status
    assert_equal 0, plays_for_track.count
  end

  test "a later pull of a webhook-settled play does not duplicate it" do
    stub_last_played
    # Webhook settles the play first (the common case: pull runs each minute).
    post_webhook(payload)

    assert_equal 1, plays_for_track.count

    # Pull then sees the same completion under the same LastPlayedDate key.
    source = Rewind::Source.where(user_id: @user.id, type: "jellyfin").first
    Rewind::Services::Sync.record_play(
      source,
      item_id: @track.id,
      source_event_id: "jellyfin:#{TRACK_JF_ID}:#{LAST_PLAYED}",
      played_at: Time.parse(LAST_PLAYED)
    )

    assert_equal 1, plays_for_track.count # pull skipped the duplicate
  end
end
