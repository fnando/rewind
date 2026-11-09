# frozen_string_literal: true

require "test_helper"

class JellyfinServiceTest < Minitest::Test
  def stub_public_users(url, users)
    WebMock.stub_request(:get, "#{url}/Users/Public")
           .to_return(status: 200, body: users.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  test "returns id/name pairs from /Users/Public" do
    stub_public_users(
      "https://jf.test",
      [
        {"Id" => "abc", "Name" => "fnando"},
        {"Id" => "def", "Name" => "guga"}
      ]
    )

    users = Rewind::Services::Jellyfin.public_users("https://jf.test/")

    assert_equal(
      [{id: "abc", name: "fnando"}, {id: "def", name: "guga"}],
      users
    )
  end

  test "returns an empty list when the server is unreachable" do
    WebMock.stub_request(:get, "https://down.test/Users/Public").to_timeout

    assert_empty Rewind::Services::Jellyfin.public_users("https://down.test")
  end

  test "returns an empty list for a non-success response" do
    WebMock.stub_request(:get, "https://jf.test/Users/Public")
           .to_return(status: 404)

    assert_empty Rewind::Services::Jellyfin.public_users("https://jf.test")
  end

  test "authenticate returns the access token and jellyfin user" do
    WebMock.stub_request(:post, "https://jf.test/Users/AuthenticateByName")
           .with(body: {Username: "fnando", Pw: "secret"}.to_json)
           .to_return(
             status: 200,
             body: {
               "AccessToken" => "tok-123",
               "User" => {"Id" => "u-1", "Name" => "fnando"},
               "ServerId" => "srv-9"
             }.to_json,
             headers: {"Content-Type" => "application/json"}
           )

    result = Rewind::Services::Jellyfin.new("https://jf.test/")
                                       .authenticate(username: "fnando",
                                                     password: "secret")

    assert_equal(
      {
        access_token: "tok-123", user_id: "u-1", user_name: "fnando",
        server_id: "srv-9"
      },
      result
    )
  end

  test "authenticate sends the given device id in the auth header" do
    WebMock.stub_request(:post, "https://jf.test/Users/AuthenticateByName")
           .with(headers: {"Authorization" => /DeviceId="dev-123"/})
           .to_return(
             status: 200,
             body: {
               "AccessToken" => "t", "User" => {"Id" => "u"},
               "ServerId" => "s"
             }.to_json,
             headers: {"Content-Type" => "application/json"}
           )

    client = Rewind::Services::Jellyfin.new("https://jf.test",
                                            device_id: "dev-123")
    result = client.authenticate(username: "a", password: "b")

    assert_equal "t", result[:access_token]
  end

  test "authenticate raises AuthError on invalid credentials" do
    WebMock.stub_request(:post, "https://jf.test/Users/AuthenticateByName")
           .to_return(status: 401)

    assert_raises(Rewind::Services::Jellyfin::AuthError) do
      Rewind::Services::Jellyfin.new("https://jf.test")
                                .authenticate(username: "x", password: "y")
    end
  end

  test "album_tracks lists the audio children of an album" do
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .with(query: hash_including("ParentId" => "alb-1",
                                       "IncludeItemTypes" => "Audio"))
           .to_return(
             status: 200,
             body: {
               "Items" => [
                 {"Id" => "t1", "Name" => "One", "IndexNumber" => 1},
                 {"Id" => "t2", "Name" => "Two", "IndexNumber" => 2}
               ]
             }.to_json,
             headers: {"Content-Type" => "application/json"}
           )

    tracks = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
                                       .album_tracks(user_id: "u-1",
                                                     album_id: "alb-1")

    assert_equal(%w[t1 t2], tracks.map {|t| t["Id"] })
  end

  test "album_tracks returns an empty list on failure" do
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .with(query: hash_including("ParentId" => "alb-x"))
           .to_return(status: 500)

    tracks = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
                                       .album_tracks(user_id: "u-1",
                                                     album_id: "alb-x")

    assert_empty tracks
  end

  test "album_release_type reads the type from the AudioMetadata plugin" do
    WebMock.stub_request(:get, "https://jf.test/AudioMetadata/Album/alb-9")
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {"Tracks" => [{"ReleaseType" => "Single"}]}.to_json)

    type = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
                                     .album_release_type("alb-9")

    assert_equal "single", type
  end

  test "album_release_type is nil when the plugin is absent" do
    WebMock.stub_request(:get, "https://jf.test/AudioMetadata/Album/nope")
           .to_return(status: 404)

    type = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
                                     .album_release_type("nope")

    assert_nil type
  end

  test "album_metadata reads release, artist and per-track ids" do
    WebMock.stub_request(:get, "https://jf.test/AudioMetadata/Album/alb-1")
           .to_return(
             status: 200, headers: {"Content-Type" => "application/json"},
             body: {
               "Tracks" => [
                 {
                   "ItemId" => "jf-t1",
                   "ReleaseType" => "Album",
                   "MusicBrainzAlbumId" => "rel-1",
                   # The plugin's curated recording id.
                   "MusicBrainzTrackId" => "rec-1",
                   "RawTags" => {
                     "MUSICBRAINZ_RELEASETRACKID" => "rt-1",
                     # Multi-artist tracks join ids with ';'; we take the first.
                     "MUSICBRAINZ_ALBUMARTISTID" => "art-1; art-2",
                     "ALBUMARTISTS" => "Artist One; Artist Two"
                   }
                 }
               ]
             }.to_json
           )

    meta = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
                                     .album_metadata("alb-1")

    assert_equal "album", meta[:release_type]
    assert_equal "rel-1", meta[:release]
    assert_equal "art-1", meta[:artist]
    assert_equal "Artist One", meta[:artist_name]
    assert_equal(
      [{item_id: "jf-t1", release_track: "rt-1", recording: "rec-1"}],
      meta[:tracks]
    )
  end

  test "album_tracks and artist_albums ask for the structured AlbumArtists" do
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u/Items})
           .to_return(status: 200, body: {"Items" => []}.to_json,
                      headers: {"Content-Type" => "application/json"})
    client = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")

    client.album_tracks(user_id: "u", album_id: "alb")
    client.artist_albums(user_id: "u", artist_id: "art")

    pattern = %r{https://jf\.test/Users/u/Items}
    assert_requested(:get, pattern, times: 2) do |req|
      req.uri.query_values["Fields"].to_s.include?("AlbumArtists")
    end
  end

  test "album_metadata is empty when the plugin is absent" do
    WebMock.stub_request(:get, "https://jf.test/AudioMetadata/Album/x")
           .to_return(status: 404)

    meta = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
                                     .album_metadata("x")

    assert_empty meta
  end

  def item_present?(status)
    WebMock.stub_request(:get, "https://jf.test/Users/u/Items/it")
           .to_return(status: status)
    Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
                              .item_present?(user_id: "u", item_id: "it")
  end

  test "item_present? maps status to a tri-state (404 alone means gone)" do
    # 2xx -> present, 404 -> gone, anything else -> unknown (never a false
    # delete, so an outage can't trigger a wrong re-tag merge).
    assert_equal(
      [true, false, :unknown, :unknown],
      [
        item_present?(200), item_present?(404),
        item_present?(500), item_present?(401)
      ]
    )
  end

  def client
    Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
  end

  test "rewind_changes reads a page of the plugin's changes feed" do
    WebMock.stub_request(:get, "https://jf.test/Rewind/History/Changes")
           .with(query: {"since" => "12", "limit" => "1000"},
                 headers: {"Authorization" => 'MediaBrowser Token="t"'})
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {
                        "items" => [{"id" => "p1"}], "nextSince" => 13,
                        "hasMore" => false
                      }.to_json)

    page = client.rewind_changes(since: 12)

    assert_equal 13, page["nextSince"]
    assert_equal(["p1"], page["items"].map { it["id"] })
  end

  test "rewind_changes reports a server without the plugin" do
    WebMock.stub_request(:get, %r{https://jf\.test/Rewind/History/Changes})
           .to_return(status: 404)

    assert_raises(Rewind::Services::Jellyfin::PluginMissing) do
      client.rewind_changes(since: 0)
    end
  end

  test "library_item asks for the fields the resolver reads" do
    WebMock.stub_request(:get, "https://jf.test/Users/u-1/Items/m1")
           .with(query: {"Fields" => Rewind::Services::Jellyfin::ITEM_FIELDS})
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {"Id" => "m1", "Etag" => "e"}.to_json)

    assert_equal "e", client.library_item(user_id: "u-1", item_id: "m1")["Etag"]
  end

  test "library_item is nil for a deleted item and raises on failures" do
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items/gone})
           .to_return(status: 404)
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items/down})
           .to_return(status: 503)

    assert_nil client.library_item(user_id: "u-1", item_id: "gone")
    assert_raises(Rewind::Services::Jellyfin::Error) do
      client.library_item(user_id: "u-1", item_id: "down")
    end
  end

  test "server_id reads the id from the public system info" do
    WebMock.stub_request(:get, "https://jf.test/System/Info/Public")
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {"Id" => "srv-1"}.to_json)

    assert_equal "srv-1", client.server_id
  end

  test "rewind_info confirms the plugin without signing in" do
    WebMock.stub_request(:get, "https://jf.test/Rewind/Info")
           .with {|request| request.headers["Authorization"].nil? }
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {
                        "id" => Rewind::Services::Jellyfin::PLUGIN_ID,
                        "version" => "1.0.0"
                      }.to_json)

    info = Rewind::Services::Jellyfin.new("https://jf.test").rewind_info

    assert_equal "1.0.0", info["version"]
  end

  test "rewind_info accepts the id as Jellyfin writes it, without dashes" do
    WebMock.stub_request(:get, "https://jf.test/Rewind/Info")
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {
                        "id" => "6bcfddb4c3fb48f6996f5b02d07e3e62",
                        "name" => "Rewind",
                        "version" => "0.0.0.0"
                      }.to_json)

    info = Rewind::Services::Jellyfin.new("https://jf.test").rewind_info

    assert_equal "Rewind", info["name"]
  end

  test "rewind_info reports a server without the plugin" do
    WebMock.stub_request(:get, "https://bare.test/Rewind/Info")
           .to_return(status: 404)
    # Something else answering on that path isn't the plugin either.
    WebMock.stub_request(:get, "https://other.test/Rewind/Info")
           .to_return(status: 200, body: "<html></html>")

    %w[https://bare.test https://other.test].each do |url|
      assert_raises(Rewind::Services::Jellyfin::PluginMissing) do
        Rewind::Services::Jellyfin.new(url).rewind_info
      end
    end
  end

  test "rewind_changes rejects a response that isn't the feed" do
    WebMock.stub_request(:get, %r{https://jf\.test/Rewind/History/Changes})
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {"Items" => [], "NextSince" => 0}.to_json)

    error = assert_raises(Rewind::Services::Jellyfin::Error) do
      client.rewind_changes(since: 0)
    end

    assert_match(/Unexpected Rewind changes response/, error.message)
  end
end
