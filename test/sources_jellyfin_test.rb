# frozen_string_literal: true

require "test_helper"

class SourcesJellyfinTest < Minitest::Test
  def setup
    @user = create_user
    @source = create_source(user_id: @user.id, url: "https://jf.test",
                            external_user_id: "u-1", access_token: "tok")
  end

  def adapter
    Rewind::Services::Sources::Jellyfin.new(@source)
  end

  def stub_items(items)
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items\?})
           .to_return(status: 200,
                      body: {
                        "Items" => items,
                        "TotalRecordCount" => items.size
                      }.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  def movie_item(id: "m1", last_played: "2026-10-16T05:00:00Z")
    {
      "Id" => id, "Type" => "Movie", "Name" => "Inception",
      "ProviderIds" => {"Tmdb" => "27205"},
      "UserData" => {"LastPlayedDate" => last_played}
    }
  end

  test "resolves a movie item to an Item" do
    stub_tmdb_movie(27_205)

    item = adapter.resolve(movie_item)

    assert_equal "movie", item.media_type
    assert_equal "tmdb:27205", item.external_id
  end

  def pinchflat_episode
    {
      "Id" => "ep-jf-1", "Type" => "Episode", "Name" => "ESCRITÓRIO CHATGPT",
      "RunTimeTicks" => 1_800_243_080, "PremiereDate" => "2026-07-01T00:00:00Z",
      "ProductionYear" => 2026, "IndexNumber" => 70_198,
      "ParentIndexNumber" => 2026,
      "ProviderIds" => {"youtube" => "9n6sxWtYz6I"},
      "SeriesName" => "Porta dos Fundos", "SeriesId" => "series-jf-1",
      "SeriesPrimaryImageTag" => "stag", "ImageTags" => {"Primary" => "etag"},
      "UserData" => {"LastPlayedDate" => "2026-10-05T03:53:30Z"}
    }
  end

  test "keeps an unmatched Jellyfin episode as a generic series + episode" do
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items/series-jf-1})
           .to_return(status: 200, body: {"ProviderIds" => {}}.to_json,
                      headers: {"Content-Type" => "application/json"})

    item = adapter.resolve(pinchflat_episode)

    assert_equal "episode", item.media_type
    assert_equal "youtube:9n6sxWtYz6I", item.external_id
    assert_equal "jellyfin:series-jf-1", item.parent_external_id
    assert_equal "ESCRITÓRIO CHATGPT", item.title
    assert_equal "2026-07-01", item.release_date
    assert_equal 3, item.runtime
    assert_equal "jellyfin", item.metadata["source"]
    assert_includes item.poster_path, "/Items/ep-jf-1/Images/Primary?tag=etag"

    series = Rewind::Item.where(media_type: "series",
                                external_id: "jellyfin:series-jf-1").first

    refute_nil series
    assert_equal "Porta dos Fundos", series.title
    assert_includes series.poster_path,
                    "/Items/series-jf-1/Images/Primary?tag=stag"
  end

  test "keeps a standalone Video as a generic movie" do
    item = adapter.resolve(
      "Id" => "vid-1", "Type" => "Video", "Name" => "Photography Course",
      "ImageTags" => {"Primary" => "ptag"},
      "ProviderIds" => {"youtube" => "abc123"},
      "UserData" => {"LastPlayedDate" => "2026-10-16T05:00:00Z"}
    )

    assert_equal "movie", item.media_type
    assert_equal "youtube:abc123", item.external_id
    assert_equal "Photography Course", item.title
    assert_equal "jellyfin", item.metadata["source"]
    assert_includes item.poster_path, "/Items/vid-1/Images/Primary?tag=ptag"
  end

  def stub_item(id, attrs)
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items/#{id}\z})
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {"Id" => id}.merge(attrs).to_json)
  end

  test "groups a video in a nested folder under a folder-named series" do
    # video -> "35mm…" (series folder) -> "other" (library root folder) -> lib
    stub_item("f-sub", "Type" => "Folder", "ParentId" => "f-root",
                       "Name" => "35mm Film Photography",
                       "ImageTags" => {"Primary" => "ft"})
    stub_item("f-root", "Type" => "Folder", "Name" => "other",
                        "ParentId" => "coll")

    item = adapter.resolve(
      "Id" => "v9", "Type" => "Video", "Name" => "001 - Intro",
      "ParentId" => "f-sub", "ImageTags" => {"Primary" => "et"},
      "UserData" => {"LastPlayedDate" => "2026-10-16T05:00:00Z"}
    )

    assert_equal "episode", item.media_type
    assert_equal "jellyfin:f-sub", item.parent_external_id

    series = Rewind::Item.where(media_type: "series",
                                external_id: "jellyfin:f-sub").first

    refute_nil series
    assert_equal "35mm Film Photography", series.title
  end

  test "keeps a loose video in the library root as a standalone movie" do
    # video -> "other" (library root folder) -> library (CollectionFolder)
    stub_item("f-root", "Type" => "Folder", "Name" => "other",
                        "ParentId" => "coll")
    stub_item("coll", "Type" => "CollectionFolder", "Name" => "other")

    item = adapter.resolve(
      "Id" => "v10", "Type" => "Video", "Name" => "A Fat Wreck",
      "ParentId" => "f-root",
      "UserData" => {"LastPlayedDate" => "2026-10-16T05:00:00Z"}
    )

    assert_equal "movie", item.media_type
    assert_equal "jellyfin:v10", item.external_id
  end

  test "keeps a watched item with no play date as a null-dated play" do
    stub_tmdb_movie(27_205)
    stub_items([
      {
        "Id" => "m2", "Type" => "Movie", "Name" => "Inception",
        "ProviderIds" => {"Tmdb" => "27205"},
        "UserData" => {"Played" => true}
      }
    ])

    play = adapter.recent_plays(since: nil)[:plays].first

    assert_nil play[:played_at]
    assert_equal "jellyfin:m2:played", play[:source_event_id]
  end

  test "anchors a dateless play to DateCreated when available" do
    stub_tmdb_movie(27_205)
    stub_items([
      {
        "Id" => "m3", "Type" => "Movie", "Name" => "Inception",
        "ProviderIds" => {"Tmdb" => "27205"},
        "DateCreated" => "2025-01-02T00:00:00Z",
        "UserData" => {"Played" => true}
      }
    ])

    play = adapter.recent_plays(since: nil)[:plays].first

    assert_equal Time.parse("2025-01-02T00:00:00Z"), play[:played_at]
    assert_equal "jellyfin:m3:played", play[:source_event_id]
  end

  test "dumps the raw fields for every item, even resolved ones" do
    stub_tmdb_movie(27_205)
    stub_items([movie_item(id: "m1")])

    io = StringIO.new
    level = Rewind.logger.level
    Rewind.logger.reopen(io)
    Rewind.logger.level = Logger::DEBUG

    begin
      adapter.recent_plays(since: nil)
    ensure
      Rewind.logger.level = level
      Rewind.logger.reopen($stdout)
    end

    assert_includes io.string, %[fields: {"Id":"m1"]
    assert_includes io.string, "resolved Movie"
  end

  test "logs items it still can't keep so skips are visible with --verbose" do
    # Audio with no name can't resolve and has no fallback.
    stub_items([
      {
        "Id" => "a1", "Type" => "Audio",
        "UserData" => {"LastPlayedDate" => "2026-10-16T05:00:00Z"}
      }
    ])

    io = StringIO.new
    level = Rewind.logger.level
    Rewind.logger.reopen(io)
    Rewind.logger.level = Logger::DEBUG

    begin
      result = adapter.recent_plays(since: nil)
    ensure
      Rewind.logger.level = level
      Rewind.logger.reopen($stdout)
    end

    assert_empty result[:plays]
    assert_includes io.string, "fetched 1 played items"
    assert_includes io.string, "skipped Audio nil (a1)"
    assert_includes io.string, "no TMDB/MusicBrainz match"
    assert_includes io.string, %[fields: {"Id":"a1"]
  end

  test "resolves an episode via the series' TMDB id" do
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items/series-1})
           .to_return(status: 200,
                      body: {"ProviderIds" => {"Tmdb" => "1399"}}.to_json,
                      headers: {"Content-Type" => "application/json"})
    stub_tmdb_tv(1399)
    stub_tmdb_episode(1399, 1, 2)

    item = adapter.resolve(
      "Id" => "e1", "Type" => "Episode", "SeriesId" => "series-1",
      "ParentIndexNumber" => 1, "IndexNumber" => 2,
      "UserData" => {"LastPlayedDate" => "2026-10-16T05:00:00Z"}
    )

    assert_equal "episode", item.media_type
    assert_equal 2, item.episode_number
  end

  test "resolves an audio item from its MusicBrainz provider ids" do
    item = adapter.resolve(
      "Id" => "a1", "Type" => "Audio", "Name" => "Burnout",
      "Album" => "Dookie", "AlbumArtist" => "Green Day",
      "RunTimeTicks" => 1_280_000_000,
      "ProviderIds" => {
        "MusicBrainzRecording" => "rec-1",
        "MusicBrainzReleaseGroup" => "rg-1",
        "MusicBrainzAlbumArtist" => "art-1"
      },
      "UserData" => {"LastPlayedDate" => "2026-10-16T05:00:00Z"}
    )

    assert_equal "track", item.media_type
    assert_equal "mbid:rec-1", item.external_id
    assert_equal "Green Day", item.artist
  end

  def audio_item(id:, name:, index:, parent_id: "alb-1")
    {
      "Id" => id, "Type" => "Audio", "Name" => name,
      "Album" => "Dookie", "AlbumArtist" => "Green Day",
      "ParentId" => parent_id, "IndexNumber" => index,
      "UserData" => {"LastPlayedDate" => "2026-10-16T05:00:00Z"}
    }
  end

  def stub_album_tracks(album_id, items)
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .with(query: hash_including("ParentId" => album_id,
                                       "IncludeItemTypes" => "Audio"))
           .to_return(status: 200,
                      body: {"Items" => items}.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  test "backfills an album's unplayed tracks from a played one" do
    stub_album_tracks("alb-1", [
      audio_item(id: "a1", name: "Burnout", index: 1),
      audio_item(id: "a2", name: "Having a Blast", index: 2),
      audio_item(id: "a3", name: "Chump", index: 3)
    ])

    adapter.resolve(audio_item(id: "a1", name: "Burnout", index: 1))

    tracks = Rewind::Item.where(media_type: "track").order(:title).all

    assert_equal ["Burnout", "Chump", "Having a Blast"], tracks.map(&:title)
    assert_equal [1, 3, 2], tracks.map(&:track_number)
    # None of the backfilled tracks carry a play — plays come from recent_plays.
    assert_equal 0, Rewind::Play.count
  end

  test "fetches an album's tracklist at most once per run" do
    stub_album_tracks("alb-1", [
      audio_item(id: "a1", name: "Burnout", index: 1),
      audio_item(id: "a2", name: "Having a Blast", index: 2)
    ])

    client = adapter
    client.resolve(audio_item(id: "a1", name: "Burnout", index: 1))
    client.resolve(audio_item(id: "a2", name: "Having a Blast", index: 2))

    assert_requested(:get, %r{https://jf\.test/Users/u-1/Items},
                     times: 1,
                     query: hash_including("ParentId" => "alb-1"))
  end

  test "stores the album's release date and genres from a played track" do
    stub_album_tracks("alb-1", [])

    adapter.resolve(
      audio_item(id: "a1", name: "Burnout", index: 1).merge(
        "PremiereDate" => "1994-02-01T00:00:00Z",
        "Genres" => ["Punk Rock", "Alternative Rock"]
      )
    )

    album = Rewind::Item.where(media_type: "album").first

    assert_equal "1994-02-01", album.release_date
    assert_equal ["Punk Rock", "Alternative Rock"], album.genres
  end

  test "re-fetches the tracklist on a later run to pick up new tracks" do
    stub_album_tracks("alb-1", [
      audio_item(id: "a1", name: "Burnout", index: 1)
    ])
    adapter.resolve(audio_item(id: "a1", name: "Burnout", index: 1))

    # A brand-new adapter (next sync run) re-fetches — no time-based cache.
    adapter.resolve(audio_item(id: "a1", name: "Burnout", index: 1))

    assert_requested(:get, %r{https://jf\.test/Users/u-1/Items},
                     times: 2,
                     query: hash_including("ParentId" => "alb-1"))
  end

  test "skips a dateless audio track with no album session to anchor to" do
    stub_items([
      {
        "Id" => "a9", "Type" => "Audio", "Name" => "Ghost Play",
        "Album" => "Nowhere", "AlbumArtist" => "Nobody",
        "UserData" => {"Played" => true}
      }
    ])

    result = adapter.recent_plays(since: nil)

    assert_empty result[:plays]
    # The track is still catalogued; only the dateless play is dropped.
    refute_nil Rewind::Item.where(media_type: "track",
                                  title: "Ghost Play").first
  end

  def audio_dated(id:, name:, at:, parent_id: "alb-1")
    {
      "Id" => id, "Type" => "Audio", "Name" => name,
      "Album" => "Dookie", "AlbumArtist" => "Green Day",
      "ParentId" => parent_id, "UserData" => {"LastPlayedDate" => at}
    }
  end

  def audio_dateless(id:, name:, parent_id: "alb-1", provider_ids: nil)
    item = {
      "Id" => id, "Type" => "Audio", "Name" => name,
      "Album" => "Dookie", "AlbumArtist" => "Green Day",
      "ParentId" => parent_id, "UserData" => {"Played" => true}
    }
    item["ProviderIds"] = provider_ids if provider_ids
    item
  end

  test "anchors a dateless audio track onto its album's session" do
    stub_items([
      audio_dated(id: "d1", name: "Opener", at: "2026-10-18T20:00:00Z"),
      audio_dated(id: "d2", name: "Middle", at: "2026-10-18T20:03:00Z"),
      audio_dateless(id: "d3", name: "Closer")
    ])

    result = adapter.recent_plays(since: nil)
    closer = Rewind::Item.where(title: "Closer").first
    recovered = result[:plays].find {|p| p[:item_id] == closer.id }

    assert_equal 3, result[:plays].size
    refute_nil recovered
    # Anchored to the album's earliest session time, with a stable event id.
    assert_equal Time.parse("2026-10-18T20:00:00Z"), recovered[:played_at]
    assert_equal "jellyfin:d3:played", recovered[:source_event_id]
  end

  test "does not recover a dateless track that already has a dated play" do
    track = create_item(media_type: "track", external_id: "mbid:rec-xyz",
                        title: "Rec")
    Rewind::Play.create(
      user_id: @user.id, item_id: track.id, source: "jellyfin",
      source_event_id: "jellyfin:recA:2026-10-18T19:00:00Z",
      played_at: Time.parse("2026-10-18T19:00:00Z")
    )
    stub_items([
      audio_dated(id: "sess", name: "Session", at: "2026-10-18T20:00:00Z"),
      audio_dateless(id: "recB", name: "Rec",
                     provider_ids: {"MusicBrainzRecording" => "rec-xyz"})
    ])

    result = adapter.recent_plays(since: nil)

    refute(result[:plays].any? {|p| p[:item_id] == track.id })
  end

  test "recent_plays re-scans the lookback window before the cursor" do
    # A play dated an hour before the cursor would be cut off without the
    # 24h lookback; with it, the late-dated play is recovered.
    stub_items([
      {
        "Id" => "late", "Type" => "Audio", "Name" => "Late Dated",
        "Album" => "X", "AlbumArtist" => "Y",
        "UserData" => {"LastPlayedDate" => "2026-10-18T11:00:00Z"}
      }
    ])

    result = adapter.recent_plays(since: "2026-10-18T12:00:00Z")

    assert_equal 1, result[:plays].size
    # The cursor never rewinds behind the incoming one.
    assert_equal "2026-10-18T12:00:00Z", result[:cursor]
  end

  test "stamps the jellyfin id on a played movie" do
    stub_tmdb_movie(27_205)
    stub_items([movie_item(id: "m1")])

    adapter.recent_plays(since: nil)
    movie = Rewind::Item.where(media_type: "movie",
                               external_id: "tmdb:27205").first

    assert_equal "m1", movie.jellyfin_id
  end

  test "stamps jellyfin ids on a played audio track and its album" do
    stub_items([audio_item(id: "a1", name: "Burnout", index: 1)])

    adapter.recent_plays(since: nil)
    track = Rewind::Item.where(media_type: "track", title: "Burnout").first
    album = Rewind::Item.where(media_type: "album").first

    assert_equal "a1", track.jellyfin_id
    assert_equal "alb-1", album.jellyfin_id
  end

  test "recent_plays builds plays with a stable source_event_id and cursor" do
    stub_tmdb_movie(27_205)
    stub_items([movie_item(id: "m1", last_played: "2026-10-16T05:00:00Z")])

    result = adapter.recent_plays(since: nil)
    play = result[:plays].first

    assert_equal "jellyfin:m1:2026-10-16T05:00:00Z", play[:source_event_id]
    assert_equal "2026-10-16T05:00:00Z", result[:cursor]
    refute_nil play[:item_id]
  end
end
