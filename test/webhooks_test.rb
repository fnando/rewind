# frozen_string_literal: true

require "test_helper"

class WebhooksTest < Minitest::Test
  SERVER_URL = "https://jellyfin.test"

  def setup
    @token = Rewind::Webhook.generate_token
    @webhook = Rewind::Webhook.new(type: "jellyfin", url: SERVER_URL)
    @webhook.token = @token
    @webhook.save

    @user = create_user
    @integration = Rewind::Integration.create(
      user_id: @user.id,
      webhook_id: @webhook.id,
      external_user_id: "jf-user-1"
    )
  end

  def fixture(name)
    File.read(File.join(__dir__, "fixtures/jellyfin/#{name}.json"))
  end

  def webhook_url(token = @token)
    "/webhooks/jellyfin/#{token}"
  end

  test "returns 404 for unknown token" do
    post "/webhooks/jellyfin/does-not-exist", fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 404, last_response.status
  end

  test "records a play for a completed movie" do
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    play = Rewind::Play.last

    assert_equal "jellyfin", play.source
    assert_equal @user.id, play.user_id
    assert_equal @integration.id, play.integration_id
    assert_equal "Inception", play.item.title
  end

  test "is idempotent on repeated events" do
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    assert_equal 1, Rewind::Play.where(integration_id: @integration.id).count
  end

  test "skips incomplete playback" do
    post webhook_url, fixture("playback_stop_incomplete"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 204, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "records a tv episode" do
    stub_tmdb_tv(1399)
    stub_tmdb_episode(1399, 1, 2)
    post webhook_url, fixture("playback_stop_episode"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    play = Rewind::Play.last

    assert_equal "episode", play.item.media_type
    assert_equal 1, play.item.season_number
    assert_equal 2, play.item.episode_number
  end

  test "ignores event when no user has claimed the Jellyfin id" do
    @integration.update(external_user_id: "someone-else")
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 204, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "routes to the user who claimed the Jellyfin id" do
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    assert_equal @user.id, Rewind::Play.last.user_id
  end

  test "two instances scope idempotency separately" do
    other_token = Rewind::Webhook.generate_token
    other_webhook = Rewind::Webhook.new(type: "jellyfin",
                                        url: "https://bedroom.test")
    other_webhook.token = other_token
    other_webhook.save
    Rewind::Integration.create(user_id: @user.id, webhook_id: other_webhook.id,
                               external_user_id: "jf-user-1")

    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"
    post webhook_url(other_token), fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 2, Rewind::Play.count
  end

  test "progress event at >=85% records a play" do
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_progress_85"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    assert_equal 1, Rewind::Play.count
  end

  test "progress event under threshold is ignored" do
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_progress_30"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 204, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "progress then stop in the same session records only one play" do
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_progress_85"),
         "CONTENT_TYPE" => "application/json"
    # mimic a stop event in the same session
    stop_payload = JSON.parse(fixture("playback_progress_85"))
    stop_payload["NotificationType"] = "PlaybackStop"
    stop_payload["PlayedToCompletion"] = true
    post webhook_url, stop_payload.to_json, "CONTENT_TYPE" => "application/json"

    assert_equal 1, Rewind::Play.count
  end

  test "falls back to IMDB lookup when TMDB id is missing (movie)" do
    stub_tmdb_find_imdb("tt1375666", movie_results: [{"id" => 27_205}])
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie_imdb_only"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    assert_equal "Inception", Rewind::Play.last.item.title
  end

  test "falls back to IMDB lookup when series TMDB id is missing (episode)" do
    stub_tmdb_find_imdb("tt0944947", tv_results: [{"id" => 1399}])
    stub_tmdb_tv(1399)
    stub_tmdb_episode(1399, 1, 2)
    post webhook_url, fixture("playback_stop_episode_imdb_only"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    assert_equal "episode", Rewind::Play.last.item.media_type
  end

  test "returns 204 when payload has no usable ids" do
    post webhook_url, fixture("playback_stop_no_ids"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 204, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "paused mapping does not record a play" do
    @integration.update(disabled_at: Time.now)
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 204, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "records a play for a completed track" do
    stub_mb_recording("rec-111", title: "Paranoid")
    post webhook_url, fixture("playback_stop_audio"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    play = Rewind::Play.last

    assert_equal "jellyfin", play.source
    assert_equal "track", play.item.media_type
    assert_equal "Paranoid", play.item.title
    assert_equal "Black Sabbath", play.item.artist
  end

  test "records an id-less track through the synthetic chain" do
    stub_mb_search_empty
    post webhook_url, fixture("playback_stop_audio_no_mbid"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    play = Rewind::Play.last

    assert_equal "track", play.item.media_type
    assert_equal "Bedroom Take", play.item.title
    assert_equal "Unsigned Band", play.item.artist
  end

  test "ignores an audio event with no title" do
    payload = JSON.parse(fixture("playback_stop_audio"))
    payload.delete("Name")
    post webhook_url, payload.to_json, "CONTENT_TYPE" => "application/json"

    assert_equal 204, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "a track replay after its (short) length is not deduped" do
    stub_mb_recording("rec-111", title: "Paranoid")

    first = JSON.parse(fixture("playback_stop_audio"))
    first["Id"] = "play-a"
    first["UtcTimestamp"] = (Time.now - 300).utc.iso8601
    post webhook_url, first.to_json, "CONTENT_TYPE" => "application/json"

    second = JSON.parse(fixture("playback_stop_audio"))
    second["Id"] = "play-b"
    second["UtcTimestamp"] = Time.now.utc.iso8601
    post webhook_url, second.to_json, "CONTENT_TYPE" => "application/json"

    # RunTimeTicks is 240s, so two listens 300s apart are distinct plays —
    # the old 30-minute floor would have wrongly dropped the second.
    assert_equal 2, Rewind::Play.count
  end

  test "disabled instance returns 403" do
    @webhook.update(enabled: false)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 403, last_response.status
  end
end
