# frozen_string_literal: true

require "test_helper"

class WebhooksTest < Minitest::Test
  def setup
    @user = create_user
    @integration = Rewind::Integration.create(
      user_id: @user.id,
      kind: "jellyfin",
      label: "Living room",
      external_user_id: "jf-user-1",
      token: Rewind::Integration.generate_token
    )
  end

  def fixture(name)
    File.read(File.join(__dir__, "fixtures/jellyfin/#{name}.json"))
  end

  def webhook_url(integration = @integration)
    "/webhooks/jellyfin/#{integration.token}"
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

  test "ignores event when external_user_id does not match" do
    @integration.update(external_user_id: "someone-else")
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 204, last_response.status
    assert_equal 0, Rewind::Play.count
  end

  test "accepts event when external_user_id matches" do
    @integration.update(external_user_id: "jf-user-1")
    stub_tmdb_movie(27_205)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
  end

  test "two integrations scope idempotency separately" do
    other = Rewind::Integration.create(
      user_id: @user.id, kind: "jellyfin", label: "Bedroom",
      external_user_id: "jf-user-1", token: Rewind::Integration.generate_token
    )
    stub_tmdb_movie(27_205)
    post webhook_url(@integration), fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"
    post webhook_url(other), fixture("playback_stop_movie"),
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

  test "disabled integration returns 403" do
    @integration.update(disabled_at: Time.now)
    post webhook_url, fixture("playback_stop_movie"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 403, last_response.status
  end
end
