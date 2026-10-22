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

  def item(id, last_played, name: "Movie")
    {
      "Id" => id, "ItemType" => "Movie", "Name" => name,
      "UserData" => {"LastPlayedDate" => last_played, "Played" => true}
    }
  end

  def stub_items(body, start_index: 0)
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .with(query: hash_including("StartIndex" => start_index.to_s))
           .to_return(status: 200, body: body.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  test "authenticate returns the access token and jellyfin user id" do
    WebMock.stub_request(:post, "https://jf.test/Users/AuthenticateByName")
           .with(body: {Username: "fnando", Pw: "secret"}.to_json)
           .to_return(
             status: 200,
             body: {
               "AccessToken" => "tok-123",
               "User" => {"Id" => "u-1"},
               "ServerId" => "srv-9"
             }.to_json,
             headers: {"Content-Type" => "application/json"}
           )

    result = Rewind::Services::Jellyfin.new("https://jf.test/")
                                       .authenticate(username: "fnando",
                                                     password: "secret")

    assert_equal(
      {access_token: "tok-123", user_id: "u-1", server_id: "srv-9"}, result
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

  test "played_items returns only items newer than the cursor" do
    stub_items({
                 "Items" => [
                   item("a", "2026-10-16T05:00:00Z"),
                   item("b", "2026-10-16T04:00:00Z"),
                   item("c", "2026-10-16T03:00:00Z")
                 ], "TotalRecordCount" => 3
               })

    client = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
    items = client.played_items(user_id: "u-1", since: "2026-10-16T04:00:00Z")

    assert_equal(%w[a], items.map {|i| i["Id"] })
  end

  def undated(id, parent: nil)
    item = {
      "Id" => id, "ItemType" => "Audio", "Name" => id,
      "UserData" => {"Played" => true}
    }
    item["ParentId"] = parent if parent
    item
  end

  def dated(id, played, parent: nil)
    item = item(id, played)
    item["ParentId"] = parent if parent
    item
  end

  test "played_items catches undated IsPlayed tracks on a played album" do
    # Descending scan early-returns at the cursor, before any undated tail.
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .with(query: hash_including("SortOrder" => "Descending"))
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {
                        "Items" => [
                          dated("new", "2026-10-16T05:00:00Z", parent: "alb"),
                          dated("old", "2026-10-16T03:00:00Z", parent: "alb")
                        ], "TotalRecordCount" => 2
                      }.to_json)
    # Ascending scan: undated IsPlayed items sort first, then a dated one. "u3"
    # is on an album not in this batch, so it's left for a full scan.
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .with(query: hash_including("SortOrder" => "Ascending"))
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {
                        "Items" => [
                          undated("u1", parent: "alb"),
                          undated("u2", parent: "alb"),
                          undated("u3", parent: "other"),
                          dated("d", "2026-10-16T02:00:00Z", parent: "alb")
                        ], "TotalRecordCount" => 4
                      }.to_json)

    client = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
    items = client.played_items(user_id: "u-1", since: "2026-10-16T04:00:00Z")

    assert_equal(%w[new u1 u2], items.map {|i| i["Id"] })
  end

  test "played_items skips the undated query on a full scan" do
    stub_items({
                 "Items" => [item("a", "2026-10-16T05:00:00Z")],
                 "TotalRecordCount" => 1
               })

    Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
                              .played_items(user_id: "u-1")

    refute_requested(:get, %r{https://jf\.test/Users/u-1/Items},
                     query: hash_including("SortOrder" => "Ascending"))
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
                     "MUSICBRAINZ_ALBUMARTISTID" => "art-1; art-2"
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
    assert_equal(
      [{item_id: "jf-t1", release_track: "rt-1", recording: "rec-1"}],
      meta[:tracks]
    )
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

  test "played_items paginates until the records are exhausted" do
    stub_items({
                 "Items" => Array.new(2) do |n|
                   item("p#{n}",
                        "2026-10-16T0#{9 - n}:00:00Z")
                 end,
                 "TotalRecordCount" => 4
               }, start_index: 0)
    stub_items({
                 "Items" => Array.new(2) do |n|
                   item("q#{n}",
                        "2026-10-16T0#{3 - n}:00:00Z")
                 end,
                 "TotalRecordCount" => 4
               }, start_index: 2)

    items = Rewind::Services::Jellyfin.new("https://jf.test", token: "t",
                                                              page_size: 2)
                                      .played_items(user_id: "u-1")

    assert_equal(%w[p0 p1 q0 q1], items.map {|i| i["Id"] })
  end
end
