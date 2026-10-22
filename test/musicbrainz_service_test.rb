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
    track = resolve(release_track_mbid: "rt-1", release_mbid: "rel-1",
                    artist_mbid: "a-1", length_ms: 240_000)

    assert_equal "track", track.media_type
    assert_equal "mbid:rt:rt-1", track.external_id
    assert_equal "mbid:release:rel-1", track.parent_external_id
    assert_equal "Black Sabbath", track.artist
    assert_equal "Paranoid", track.album
    assert_equal 4, track.runtime
    assert_includes track.poster_path, "coverartarchive.org/release/rel-1"

    album = Rewind::Item.where(external_id: "mbid:release:rel-1").first

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

  test "resolve stores the jellyfin ids on the track and album" do
    track = resolve(jellyfin_id: "jf-track", album_jellyfin_id: "jf-album")

    assert_equal "jf-track", track.jellyfin_id
    album = Rewind::Item.where(media_type: "album").first

    assert_equal "jf-album", album.jellyfin_id
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

  def map(from, to)
    Rewind.db[:item_merges].insert(from_external_id: from, to_external_id: to,
                                   created_at: Time.now)
  end

  test "resolve routes a merged-away synthetic id to the mbid item" do
    original = resolve(artist: "Ghost", album: "Prequelle", title: "Rats")
    map(original.metadata["artist_external_id"], "mbid:artist:ghost-real")

    again = resolve(artist: "Ghost", album: "Prequelle", title: "Rats")

    assert_equal "mbid:artist:ghost-real", again.metadata["artist_external_id"]
  end

  test "resolve follows a merge chain to the final id" do
    original = resolve(artist: "Ghost", album: "Prequelle", title: "Rats")
    map(original.metadata["artist_external_id"], "mbid:artist:mid")
    map("mbid:artist:mid", "mbid:artist:final")

    again = resolve(artist: "Ghost", album: "Prequelle", title: "Rats")

    assert_equal "mbid:artist:final", again.metadata["artist_external_id"]
  end

  test "resolve terminates on a cyclic merge map" do
    original = resolve(artist: "Ghost", album: "Prequelle", title: "Rats")
    synth = original.metadata["artist_external_id"]
    map(synth, "mbid:artist:loop")
    map("mbid:artist:loop", synth)

    # The visited-set guard must stop the walk instead of hanging.
    again = resolve(artist: "Ghost", album: "Prequelle", title: "Rats")

    assert_equal synth, again.metadata["artist_external_id"]
  end

  test "a track without a release-track id falls back to synthetic" do
    track = resolve(release_mbid: "rel-1", artist_mbid: "a-1")

    assert track.external_id.start_with?("mbid:synthetic:track:")
    # The album still resolves by its release id.
    assert_equal "mbid:release:rel-1", track.parent_external_id
  end

  test "an album without a release id is synthetic (never a group)" do
    track = resolve(release_track_mbid: "rt-1", artist_mbid: "a-1")

    album = Rewind::Item.where(external_id: track.parent_external_id).first

    assert album.external_id.start_with?("mbid:synthetic:album:")
    refute_includes Rewind::Item.map(:external_id).join, "mbid:rg:"
  end

  test "the same song on two releases resolves to separate tracks + albums" do
    resolve(title: "Turning Back", release_track_mbid: "rt-us",
            release_mbid: "rel-us", artist_mbid: "a-1")
    resolve(title: "Turning Back", release_track_mbid: "rt-jp",
            release_mbid: "rel-jp", artist_mbid: "a-1")

    tracks = Rewind::Item.where(media_type: "track").map(:external_id).sort
    albums = Rewind::Item.where(media_type: "album").map(:external_id).sort

    assert_equal ["mbid:rt:rt-jp", "mbid:rt:rt-us"], tracks
    assert_equal ["mbid:release:rel-jp", "mbid:release:rel-us"], albums
  end
end
