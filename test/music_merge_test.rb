# frozen_string_literal: true

require "test_helper"
require "time"

class MusicMergeTest < Minitest::Test
  def setup
    @user = create_user
  end

  # A synthetic artist (with a matched album/track and an unmatched "no mbid
  # twin" album) alongside its real mbid twin. Titles differ only in case, to
  # exercise the normalized-title pairing.
  def build_scenario
    real_artist = create_item(media_type: "artist",
                              external_id: "mbid:artist:real",
                              title: "Daphne Loves Derby")
    real_album = create_item(
      media_type: "album", external_id: "mbid:rg:a",
      parent_external_id: real_artist.external_id, title: "b-sides",
      jellyfin_id: "jf-ma",
      metadata_json: {
        "artist" => "Daphne Loves Derby",
        "artist_external_id" => real_artist.external_id
      }.to_json
    )
    real_track = create_item(
      media_type: "track", external_id: "mbid:rec:a1",
      parent_external_id: real_album.external_id, title: "sundays",
      jellyfin_id: "jf-mt",
      metadata_json: {
        "artist" => "Daphne Loves Derby",
        "artist_external_id" => real_artist.external_id,
        "album" => "b-sides",
        "album_external_id" => real_album.external_id,
        "length_ms" => 180_000
      }.to_json
    )

    synth_artist = create_item(media_type: "artist",
                               external_id: "mbid:synthetic:artist:x",
                               title: "Daphne Loves Derby")
    synth_album = create_item(
      media_type: "album", external_id: "mbid:synthetic:album:x",
      parent_external_id: synth_artist.external_id, title: "B-Sides",
      jellyfin_id: "jf-sa",
      metadata_json: {
        "artist" => "Daphne Loves Derby",
        "artist_external_id" => synth_artist.external_id
      }.to_json
    )
    synth_track = create_item(
      media_type: "track", external_id: "mbid:synthetic:track:x",
      parent_external_id: synth_album.external_id, title: "Sundays",
      metadata_json: {
        "artist" => "Daphne Loves Derby",
        "artist_external_id" => synth_artist.external_id,
        "album" => "B-Sides",
        "album_external_id" => synth_album.external_id,
        "length_ms" => 180_000
      }.to_json
    )

    synth_ep = create_item(
      media_type: "album", external_id: "mbid:synthetic:album:ep",
      parent_external_id: synth_artist.external_id, title: "Demo EP",
      jellyfin_id: "jf-sep",
      metadata_json: {
        "artist" => "Daphne Loves Derby",
        "artist_external_id" => synth_artist.external_id
      }.to_json
    )
    synth_ep_track = create_item(
      media_type: "track", external_id: "mbid:synthetic:track:ep1",
      parent_external_id: synth_ep.external_id, title: "Exit",
      metadata_json: {
        "artist" => "Daphne Loves Derby",
        "artist_external_id" => synth_artist.external_id,
        "album" => "Demo EP",
        "album_external_id" => synth_ep.external_id
      }.to_json
    )

    {
      real_artist:, real_album:, real_track:, synth_artist:, synth_album:,
      synth_track:, synth_ep:, synth_ep_track:
    }
  end

  def track_play(item, at:, event:, user: @user, instance: "srv-1")
    Rewind::Play.create(
      user_id: user.id, item_id: item.id, source: "jellyfin",
      instance_id: instance, source_event_id: event,
      played_at: Time.parse(at)
    )
  end

  def merge(from:, to:)
    Rewind::Services::MusicMerge.new(from:, to:).run
  end

  test "collapses a synthetic artist onto its mbid twin, keeping plays" do
    s = build_scenario
    track_play(s[:synth_track], at: "2026-10-10 12:00:00 UTC", event: "ev-a1")
    track_play(s[:synth_ep_track], at: "2026-10-11 12:00:00 UTC",
                                   event: "ev-ep")
    Rewind::UserItem.create(user_id: @user.id,
                            item_key: s[:synth_album].rating_key, rating: 4)
    Rewind::UserItem.create(user_id: @user.id,
                            item_key: s[:synth_artist].rating_key,
                            rating: 5, review: "Great")

    summary = merge(from: s[:synth_artist], to: s[:real_artist])

    # One artist; the matched album collapsed, the unmatched one re-parented.
    assert_nil Rewind::Item[s[:synth_artist].id]
    assert_nil Rewind::Item[s[:synth_album].id]
    assert_nil Rewind::Item[s[:synth_track].id]
    assert_equal 1, Rewind::Item.where(media_type: "artist").count
    albums = Rewind::Item.where(media_type: "album",
                                parent_external_id: "mbid:artist:real").all

    assert_equal 2, albums.size

    # Plays preserved: the matched track's play moved onto the mbid track.
    assert_equal 1, Rewind::Play.where(item_id: s[:real_track].id).count
    assert_equal 1, Rewind::Play.where(item_id: s[:synth_ep_track].id).count
    assert_equal 1, summary.plays_repointed
    assert_equal 0, summary.plays_dropped

    # The re-parented track points at the real artist, name and all.
    ep_track = Rewind::Item[s[:synth_ep_track].id]

    assert_equal "mbid:artist:real", ep_track.metadata["artist_external_id"]
    assert_equal "Daphne Loves Derby", ep_track.metadata["artist"]
    assert_equal "mbid:artist:real", Rewind::Item[s[:synth_ep].id].parent_external_id

    # Ratings/reviews followed to the mbid keys.
    album_ui = Rewind::UserItem.where(user_id: @user.id,
                                      item_key: s[:real_album].rating_key).first

    assert_equal 4, album_ui.rating
    artist_key = "artist:mbid:artist:real"
    artist_ui = Rewind::UserItem.where(user_id: @user.id,
                                       item_key: artist_key).first

    assert_equal 5, artist_ui.rating
    assert_equal "Great", artist_ui.review

    # Map written (artist + album + track) and no streak drift.
    assert_equal 3, Rewind.db[:item_merges].count
    assert_equal 1,
                 Rewind.db[:item_merges].where(
                   from_external_id: "mbid:synthetic:artist:x",
                   to_external_id: "mbid:artist:real"
                 ).count
    assert_empty Rewind::Services::Streaks.verify(@user)
    assert_empty summary.drift
  end

  test "drops a duplicate listen and keeps activity consistent" do
    s = build_scenario
    # The same listen landed on both tracks (same user + played_at).
    track_play(s[:real_track], at: "2026-10-10 12:00:00 UTC", event: "ev-real")
    track_play(s[:synth_track], at: "2026-10-10 12:00:00 UTC",
                                event: "ev-synth")

    summary = merge(from: s[:synth_artist], to: s[:real_artist])

    assert_equal 1, Rewind::Play.where(item_id: s[:real_track].id).count
    assert_equal 1, summary.plays_dropped
    assert_equal 0, summary.plays_repointed
    assert_equal 1,
                 Rewind.db[:user_day_activity].where(
                   user_id: @user.id, media_group: "music", day: "2026-10-10"
                 ).get(:play_count)
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "re-parents an album with no mbid twin without losing its plays" do
    real_artist = create_item(media_type: "artist",
                              external_id: "mbid:artist:real", title: "X")
    synth_artist = create_item(media_type: "artist",
                               external_id: "mbid:synthetic:artist:y",
                               title: "X")
    synth_album = create_item(
      media_type: "album", external_id: "mbid:synthetic:album:y",
      parent_external_id: synth_artist.external_id, title: "Only EP",
      jellyfin_id: "jf-y"
    )
    synth_track = create_item(
      media_type: "track", external_id: "mbid:synthetic:track:y",
      parent_external_id: synth_album.external_id, title: "Song",
      metadata_json: {
        "artist_external_id" => synth_artist.external_id,
        "album_external_id" => synth_album.external_id,
        "artist" => "X"
      }.to_json
    )
    track_play(synth_track, at: "2026-10-12 12:00:00 UTC", event: "ev-1")

    summary = merge(from: synth_artist, to: real_artist)

    assert_nil Rewind::Item[synth_artist.id]
    assert_equal "mbid:artist:real", Rewind::Item[synth_album.id].parent_external_id
    assert_equal 1, Rewind::Play.where(item_id: synth_track.id).count
    assert_equal 1, summary.albums_reparented
    assert_equal 0, summary.albums_merged
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "folds a review and rating onto one key, flagging a rating conflict" do
    s = build_scenario
    Rewind::UserItem.create(user_id: @user.id,
                            item_key: s[:real_album].rating_key, rating: 3)
    Rewind::UserItem.create(user_id: @user.id,
                            item_key: s[:synth_album].rating_key, rating: 5,
                            review: "B-sides rule",
                            review_created_at: Time.now,
                            review_updated_at: Time.now)

    summary = merge(from: s[:synth_artist], to: s[:real_artist])

    ui = Rewind::UserItem.where(user_id: @user.id,
                                item_key: s[:real_album].rating_key).first

    assert_equal 3, ui.rating               # target rating kept on conflict
    assert_equal "B-sides rule", ui.review  # source review carried over
    assert_equal 1, summary.rating_conflicts
    leftover = Rewind::UserItem.where(item_key: s[:synth_album].rating_key)

    assert_nil leftover.first
  end

  test "refuses to merge a non-artist item" do
    s = build_scenario
    error = assert_raises(Rewind::Services::MusicMerge::Error) do
      merge(from: s[:synth_album], to: s[:real_artist])
    end
    assert_match(/must be artists/, error.message)
  end

  test "de-duplicates a synthetic album onto its mbid twin under one artist" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:real",
                         title: "DLD")
    mbid_album = create_item(
      media_type: "album", external_id: "mbid:rg:z",
      parent_external_id: artist.external_id, title: "B-Sides",
      jellyfin_id: "jf-mz",
      metadata_json: {
        "artist" => "DLD",
        "artist_external_id" => artist.external_id
      }.to_json
    )
    mbid_track = create_item(
      media_type: "track", external_id: "mbid:rec:z1",
      parent_external_id: mbid_album.external_id, title: "Sundays",
      jellyfin_id: "jf-mz1",
      metadata_json: {
        "artist_external_id" => artist.external_id,
        "album_external_id" => mbid_album.external_id,
        "artist" => "DLD"
      }.to_json
    )
    synth_album = create_item(
      media_type: "album", external_id: "mbid:synthetic:album:z",
      parent_external_id: artist.external_id, title: "B-Sides",
      jellyfin_id: "jf-sz"
    )
    synth_track = create_item(
      media_type: "track", external_id: "mbid:synthetic:track:z",
      parent_external_id: synth_album.external_id, title: "Sundays",
      metadata_json: {
        "artist_external_id" => artist.external_id,
        "album_external_id" => synth_album.external_id,
        "artist" => "DLD"
      }.to_json
    )
    track_play(synth_track, at: "2026-10-10 12:00:00 UTC", event: "ev-z")

    # Pass the same artist for from/to: a pure de-duplication pass.
    summary = merge(from: artist, to: artist)

    assert_nil Rewind::Item[synth_album.id]
    assert_nil Rewind::Item[synth_track.id]
    assert_equal 1, Rewind::Play.where(item_id: mbid_track.id).count
    assert_equal 1, summary.albums_merged
    assert_equal 1, summary.plays_repointed
    albums = Rewind::Item.where(media_type: "album",
                                parent_external_id: artist.external_id).all

    assert_equal 1, albums.size
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "de-duplicates synthetic tracks onto mbid twins within one album" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:real",
                         title: "DLD")
    album = create_item(media_type: "album", external_id: "mbid:rg:z",
                        parent_external_id: artist.external_id,
                        title: "B-Sides", jellyfin_id: "jf-z")
    mbid_track = create_item(
      media_type: "track", external_id: "mbid:rec:z1",
      parent_external_id: album.external_id, title: "Sundays",
      jellyfin_id: "jf-z1",
      metadata_json: {
        "artist_external_id" => artist.external_id,
        "album_external_id" => album.external_id,
        "artist" => "DLD"
      }.to_json
    )
    synth_track = create_item(
      media_type: "track", external_id: "mbid:synthetic:track:z",
      parent_external_id: album.external_id, title: "sundays",
      metadata_json: {
        "artist_external_id" => artist.external_id,
        "album_external_id" => album.external_id,
        "artist" => "DLD"
      }.to_json
    )
    track_play(synth_track, at: "2026-10-10 12:00:00 UTC", event: "ev-z")

    summary = merge(from: artist, to: artist)

    assert_nil Rewind::Item[synth_track.id]
    assert_equal 1, Rewind::Play.where(item_id: mbid_track.id).count
    assert_equal 1, summary.tracks_merged
    assert_equal 1, summary.plays_repointed
    tracks = Rewind::Item.where(media_type: "track",
                                parent_external_id: album.external_id).all

    assert_equal 1, tracks.size
    assert_empty Rewind::Services::Streaks.verify(@user)
  end
end
