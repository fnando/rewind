# frozen_string_literal: true

require "test_helper"

class MusicBrainzServiceTest < Minitest::Test
  REC = "rec-111"

  def service(fanart: Rewind::Services::Fanart.new(api_key: nil))
    Rewind::Services::MusicBrainz.new(fanart: fanart)
  end

  test "recording builds the artist, album and track chain" do
    stub_mb_recording(REC, title: "Paranoid", artist_name: "Black Sabbath",
                           artist_mbid: "a-1", album_title: "Paranoid",
                           rg_mbid: "rg-1")

    track = service.recording(REC)

    assert_equal "track", track.media_type
    assert_equal "mbid:#{REC}", track.external_id
    assert_equal "mbid:rg:rg-1", track.parent_external_id
    assert_equal "Black Sabbath", track.artist
    assert_equal "Paranoid", track.album
    assert_equal 4, track.runtime
    assert_includes track.poster_path, "coverartarchive.org/release-group/rg-1"

    album = Rewind::Item.where(external_id: "mbid:rg:rg-1").first

    assert_equal "album", album.media_type
    assert_equal "mbid:artist:a-1", album.parent_external_id
    assert_includes album.poster_path, "coverartarchive.org/release-group/rg-1"

    artist = Rewind::Item.where(external_id: "mbid:artist:a-1").first

    assert_equal "artist", artist.media_type
    assert_equal "Black Sabbath", artist.title
  end

  test "recording caches within the TTL without a second HTTP call" do
    stub = stub_mb_recording(REC)

    service.recording(REC)
    service.recording(REC)

    assert_requested(stub, times: 1)
  end

  test "resolve falls back to search when there is no mbid" do
    stub_mb_search(REC, title: "Found")
    stub_mb_recording(REC, title: "Found")

    track = service.resolve(artist: "A", album: "B", title: "Found")

    assert_equal "Found", track.title
    assert_equal "mbid:#{REC}", track.external_id
  end

  test "resolve builds a synthetic chain when nothing matches" do
    stub_mb_search_empty

    track = service.resolve(artist: "Nobody", album: "Demo",
                            title: "Untitled", length_ms: 180_000)

    assert_equal "track", track.media_type
    assert track.external_id.start_with?("mbid:synthetic:track:")
    assert_equal "Nobody", track.artist
    assert_equal 3, track.runtime

    album = Rewind::Item.where(external_id: track.parent_external_id).first

    assert_equal "album", album.media_type
  end

  test "resolve returns nil without a title" do
    assert_nil service.resolve(artist: "A", album: "B", title: "")
  end

  test "artist photo comes from fanart when a key is configured" do
    stub_mb_recording(REC, artist_mbid: "a-9")
    stub_fanart_artist("a-9", url: "https://fanart.example/a.jpg")

    svc = service(fanart: Rewind::Services::Fanart.new(api_key: "k"))
    svc.recording(REC)
    artist = Rewind::Item.where(external_id: "mbid:artist:a-9").first

    assert_equal "https://fanart.example/a.jpg", artist.poster_path
  end

  test "artist photo is nil when no fanart key is set" do
    stub_mb_recording(REC, artist_mbid: "a-3")

    service.recording(REC)
    artist = Rewind::Item.where(external_id: "mbid:artist:a-3").first

    assert_nil artist.poster_path
  end

  test "a non-2xx response raises an error" do
    WebMock.stub_request(:get, %r{musicbrainz\.org/ws/2/recording/#{REC}}o)
           .to_return(status: 503, body: "")

    assert_raises(Rewind::Services::MusicBrainz::Error) do
      service.recording(REC)
    end
  end
end
