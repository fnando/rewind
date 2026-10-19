# frozen_string_literal: true

require "test_helper"

class MusicBrainzServiceTest < Minitest::Test
  def service(fanart: Rewind::Services::Fanart.new(api_key: nil))
    Rewind::Services::MusicBrainz.new(fanart: fanart)
  end

  def resolve(title: "Paranoid", artist: "Black Sabbath", album: "Paranoid",
              **attrs)
    service.resolve(title: title, artist: artist, album: album, **attrs)
  end

  test "resolve with mbids builds the artist, album and track chain" do
    track = resolve(recording_mbid: "rec-1", release_group_mbid: "rg-1",
                    artist_mbid: "a-1", length_ms: 240_000)

    assert_equal "track", track.media_type
    assert_equal "mbid:rec-1", track.external_id
    assert_equal "mbid:rg:rg-1", track.parent_external_id
    assert_equal "Black Sabbath", track.artist
    assert_equal "Paranoid", track.album
    assert_equal 4, track.runtime
    assert_includes track.poster_path, "coverartarchive.org/release-group/rg-1"

    album = Rewind::Item.where(external_id: "mbid:rg:rg-1").first

    assert_equal "album", album.media_type
    assert_equal "mbid:artist:a-1", album.parent_external_id

    artist = Rewind::Item.where(external_id: "mbid:artist:a-1").first

    assert_equal "artist", artist.media_type
    assert_equal "Black Sabbath", artist.title
  end

  test "resolve without mbids builds a deterministic synthetic chain" do
    track = resolve(artist: "Nobody", album: "Demo", title: "Untitled",
                    length_ms: 180_000)

    assert_equal "track", track.media_type
    assert track.external_id.start_with?("mbid:synthetic:track:")
    assert_equal "Nobody", track.artist
    assert_equal 3, track.runtime

    album = Rewind::Item.where(external_id: track.parent_external_id).first

    assert_equal "album", album.media_type
  end

  test "the same id-less song always resolves to the same item" do
    first = resolve(artist: "Green Day", album: "Dookie", title: "Burnout")
    # Different casing must still land on one item so plays group together.
    second = resolve(artist: "green day", album: "Dookie", title: "burnout")

    assert_equal first.id, second.id
    assert_equal 1, Rewind::Item.where(media_type: "track").count
  end

  test "different id-less songs on an album are distinct tracks" do
    one = resolve(album: "Dookie", title: "Burnout")
    two = resolve(album: "Dookie", title: "Having a Blast")

    refute_equal one.external_id, two.external_id
  end

  test "artist photo comes from fanart when a key is configured" do
    stub_fanart_artist("a-9", url: "https://fanart.example/a.jpg")

    svc = service(fanart: Rewind::Services::Fanart.new(api_key: "k"))
    svc.resolve(title: "T", artist: "A", album: "B", artist_mbid: "a-9")
    artist = Rewind::Item.where(external_id: "mbid:artist:a-9").first

    assert_equal "https://fanart.example/a.jpg", artist.poster_path
  end

  test "resolve stores the track and disc numbers in metadata" do
    track = resolve(track_number: 3, disc_number: 2)

    assert_equal 3, track.track_number
    assert_equal 2, track.disc_number
  end

  test "resolve stores the album's release date and genres" do
    resolve(release_date: "2007-10-10", genres: ["Alternative Rock", ""])
    album = Rewind::Item.where(media_type: "album").first

    assert_equal "2007-10-10", album.release_date
    assert_equal ["Alternative Rock"], album.genres
  end

  test "resolve keeps the album's year and genres when a track omits them" do
    resolve(release_date: "2007-10-10", genres: ["Alternative Rock"])
    resolve(title: "Faust Arp", release_date: nil, genres: nil)
    album = Rewind::Item.where(media_type: "album").first

    assert_equal "2007-10-10", album.release_date
    assert_equal ["Alternative Rock"], album.genres
  end

  test "re-resolving refreshes fields without re-fetching the artist photo" do
    stub_fanart_artist("a-7", url: "https://fanart.example/a.jpg")
    svc = service(fanart: Rewind::Services::Fanart.new(api_key: "k"))

    svc.resolve(title: "T", artist: "A", album: "B", artist_mbid: "a-7")
    # A later play of the same track carries its number; it must land now.
    track = svc.resolve(title: "T", artist: "A", album: "B", artist_mbid: "a-7",
                        track_number: 4)

    assert_equal 4, track.track_number
    # The artist photo was stored on the first pass and reused on the second.
    assert_requested(:get, %r{webservice\.fanart\.tv/v3\.2/music/a-7},
                     times: 1)
  end

  test "resolve returns nil without a title" do
    assert_nil resolve(title: "")
  end
end
