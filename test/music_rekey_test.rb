# frozen_string_literal: true

require "test_helper"
require "time"

class MusicRekeyTest < Minitest::Test
  def setup
    @user = create_user
    @client = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
  end

  def stub_album(jellyfin_id, release:, tracks:)
    body = {
      "Tracks" => tracks.map do |t|
        {
          "ItemId" => t[:item_id], "MusicBrainzAlbumId" => release,
          "RawTags" => {"MUSICBRAINZ_RELEASETRACKID" => t[:release_track]}
        }
      end
    }
    WebMock.stub_request(
      :get, "https://jf.test/AudioMetadata/Album/#{jellyfin_id}"
    ).to_return(status: 200, headers: {"Content-Type" => "application/json"},
                body: body.to_json)
  end

  def track_meta(artist, album)
    {
      "artist" => "A", "artist_external_id" => artist.external_id,
      "album_external_id" => album.external_id
    }.to_json
  end

  def play_on(track, at:, event:)
    Rewind::Play.create(user_id: @user.id, item_id: track.id,
                        source: "jellyfin",
                        instance_id: "i", source_event_id: event,
                        played_at: Time.parse(at))
  end

  def rekey
    Rewind::Services::MusicRekey.new(client: @client).run
  end

  test "re-keys album + track in place, preserving plays" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:a",
                         title: "A")
    album = create_item(media_type: "album", external_id: "mbid:rg:old",
                        parent_external_id: artist.external_id, title: "Alb",
                        jellyfin_id: "jf-alb")
    track = create_item(media_type: "track", external_id: "mbid:oldrec",
                        parent_external_id: album.external_id, title: "T",
                        jellyfin_id: "jf-t1",
                        metadata_json: track_meta(artist, album))
    play_on(track, at: "2026-10-10 12:00:00 UTC", event: "e1")
    stub_album("jf-alb", release: "rel-1",
                         tracks: [{item_id: "jf-t1", release_track: "rt-1"}])

    summary = rekey

    # Same rows, re-keyed in place — so the play never moved.
    assert_equal "mbid:release:rel-1", Rewind::Item[album.id].external_id
    assert_equal "mbid:rt:rt-1", Rewind::Item[track.id].external_id
    assert_equal "mbid:release:rel-1", Rewind::Item[track.id].parent_external_id
    assert_equal 1, Rewind::Play.where(item_id: track.id).count
    assert_equal 1, summary.albums_rekeyed
    assert_equal 1, summary.tracks_rekeyed
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "pulls a stranded track off its old album onto the release" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:a",
                         title: "A")
    # The album the plugin reports for jf-alb (found by jellyfin_id).
    create_item(media_type: "album", external_id: "mbid:rg:old",
                parent_external_id: artist.external_id, title: "Alb",
                jellyfin_id: "jf-alb")
    # The track sits under a *different* album than the one the plugin reports.
    other = create_item(media_type: "album", external_id: "mbid:rg:other",
                        parent_external_id: artist.external_id, title: "Other")
    track = create_item(media_type: "track", external_id: "mbid:oldrec",
                        parent_external_id: other.external_id, title: "T",
                        jellyfin_id: "jf-t1",
                        metadata_json: track_meta(artist, other))
    play_on(track, at: "2026-10-10 12:00:00 UTC", event: "e1")
    stub_album("jf-alb", release: "rel-1",
                         tracks: [{item_id: "jf-t1", release_track: "rt-1"}])

    rekey

    assert_equal "mbid:release:rel-1", Rewind::Item[track.id].parent_external_id
    assert_equal 1, Rewind::Play.where(item_id: track.id).count
  end

  test "absorbs a duplicate row into the release-track one, moving plays" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:a",
                         title: "A")
    album = create_item(media_type: "album", external_id: "mbid:release:rel-1",
                        parent_external_id: artist.external_id, title: "Alb",
                        jellyfin_id: "jf-alb")
    kept = create_item(media_type: "track", external_id: "mbid:rt:rt-1",
                       parent_external_id: album.external_id, title: "T",
                       jellyfin_id: "jf-t1",
                       metadata_json: track_meta(artist, album))
    old = create_item(media_type: "track", external_id: "mbid:oldrec",
                      parent_external_id: "mbid:rg:old", title: "T",
                      jellyfin_id: "jf-t1",
                      metadata_json: track_meta(artist, album))
    play_on(old, at: "2026-10-10 12:00:00 UTC", event: "e1")
    stub_album("jf-alb", release: "rel-1",
                         tracks: [{item_id: "jf-t1", release_track: "rt-1"}])

    summary = rekey

    assert_nil Rewind::Item[old.id]
    assert_equal 1, Rewind::Play.where(item_id: kept.id).count
    assert_equal 1, summary.items_absorbed
    assert_equal 1, summary.plays_moved
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "prunes childless non-release albums but keeps release ones" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:a",
                         title: "A")
    create_item(media_type: "album", external_id: "mbid:rg:dead",
                parent_external_id: artist.external_id, title: "Dead")
    create_item(media_type: "album", external_id: "mbid:release:keep",
                parent_external_id: artist.external_id, title: "Keep",
                jellyfin_id: "jf-keep")
    WebMock.stub_request(:get, %r{https://jf\.test/AudioMetadata/Album/})
           .to_return(status: 404)

    summary = rekey

    assert_nil Rewind::Item.where(external_id: "mbid:rg:dead").first
    refute_nil Rewind::Item.where(external_id: "mbid:release:keep").first
    assert_equal 1, summary.albums_pruned
  end

  test "leaves an album untouched when the plugin doesn't know it" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:a",
                         title: "A")
    album = create_item(media_type: "album", external_id: "mbid:rg:x",
                        parent_external_id: artist.external_id, title: "X",
                        jellyfin_id: "jf-x")
    create_item(media_type: "track", external_id: "mbid:rec",
                parent_external_id: album.external_id, title: "T",
                jellyfin_id: "jf-tx")
    WebMock.stub_request(:get, %r{https://jf\.test/AudioMetadata/Album/})
           .to_return(status: 404)

    summary = rekey

    assert_equal "mbid:rg:x", Rewind::Item[album.id].external_id
    assert_equal 1, summary.skipped
  end
end
