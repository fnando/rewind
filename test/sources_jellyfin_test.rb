# frozen_string_literal: true

require "test_helper"

class SourcesJellyfinTest < Minitest::Test
  def setup
    @user = create_user
    @source = create_source(user_id: @user.id, url: "https://jf.test",
                            external_user_id: "u-1", access_token: "tok")
    # The AudioMetadata plugin is optional; default to "not installed" so
    # release-type lookups are a graceful no-op unless a test opts in.
    WebMock.stub_request(:get, %r{https://jf\.test/AudioMetadata/Album/})
           .to_return(status: 404)
  end

  def stub_release_type(album_id, type)
    WebMock.stub_request(:get, "https://jf.test/AudioMetadata/Album/#{album_id}")
           .to_return(status: 200,
                      headers: {"Content-Type" => "application/json"},
                      body: {"Tracks" => [{"ReleaseType" => type}]}.to_json)
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
        "MusicBrainzTrack" => "rt-1",
        "MusicBrainzAlbum" => "rel-1",
        "MusicBrainzAlbumArtist" => "art-1"
      },
      "UserData" => {"LastPlayedDate" => "2026-10-16T05:00:00Z"}
    )

    assert_equal "track", item.media_type
    assert_equal "mbid:rt:rt-1", item.external_id
    assert_equal "mbid:release:rel-1", item.parent_external_id
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

  test "an unchanged Etag skips the re-resolve and re-backfill next run" do
    stub_album_tracks("alb-1", [])
    tagged = audio_item(id: "a1", name: "Burnout",
                        index: 1).merge("Etag" => "v1")

    first = adapter.resolve(tagged) # run 1: resolves + backfills + stores Etag
    second = adapter.resolve(tagged) # run 2: same Etag -> cached, no backfill

    assert_equal first.id, second.id
    assert_equal "v1", first.refresh.source_etag
    assert_requested(:get, %r{https://jf\.test/Users/u-1/Items},
                     times: 1,
                     query: hash_including("ParentId" => "alb-1"))
  end

  test "a changed Etag re-resolves and re-backfills" do
    stub_album_tracks("alb-1", [])
    adapter.resolve(audio_item(id: "a1", name: "Burnout", index: 1)
                      .merge("Etag" => "v1"))
    adapter.resolve(audio_item(id: "a1", name: "Burnout", index: 1)
                      .merge("Etag" => "v2"))

    assert_requested(:get, %r{https://jf\.test/Users/u-1/Items},
                     times: 2,
                     query: hash_including("ParentId" => "alb-1"))
  end

  def stub_artist_albums(artist_id, items)
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .with(query: hash_including("AlbumArtistIds" => artist_id,
                                       "IncludeItemTypes" => "MusicAlbum"))
           .to_return(status: 200,
                      body: {"Items" => items}.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  def album_item(id:, name:, mbid:)
    {
      "Id" => id, "Type" => "MusicAlbum", "Name" => name,
      "AlbumArtist" => "Green Day",
      "ProviderIds" => {
        "MusicBrainzAlbum" => mbid,
        "MusicBrainzAlbumArtist" => "art-1"
      }
    }
  end

  # A played track carrying its MusicBrainz ids and the artist's Jellyfin id,
  # so the artist resolves to the same mbid-based id as the backfilled albums.
  def tagged_track(id: "a1", name: "Burnout")
    audio_item(id:, name:, index: 1).merge(
      "ProviderIds" => {
        "MusicBrainzTrack" => "rt-#{id}",
        # The played track's album matches album_item(Dookie, mbid: "rg-1").
        "MusicBrainzAlbum" => "rg-1",
        "MusicBrainzAlbumArtist" => "art-1"
      },
      "AlbumArtists" => [{"Name" => "Green Day", "Id" => "jf-artist-1"}]
    )
  end

  test "backfills an artist's unplayed albums from a played track" do
    stub_album_tracks("alb-1", []) # the played track's own album backfill
    stub_artist_albums("jf-artist-1", [
      album_item(id: "alb-1", name: "Dookie", mbid: "rg-1"),
      album_item(id: "alb-2", name: "Insomniac", mbid: "rg-2"),
      album_item(id: "alb-3", name: "Nimrod", mbid: "rg-3")
    ])

    adapter.resolve(tagged_track)

    artist = Rewind::Item.where(media_type: "artist").first
    albums = Rewind::Item.where(media_type: "album").order(:title).all

    assert_equal %w[Dookie Insomniac Nimrod], albums.map(&:title)
    assert(albums.all? {|a| a.parent_external_id == artist.external_id })
    # Backfilled albums carry no plays — plays come from recent_plays.
    assert_equal 0, Rewind::Play.count
  end

  test "caches an album's release type from the AudioMetadata plugin" do
    stub_album_tracks("alb-1", [])
    stub_artist_albums("jf-artist-1", [
      album_item(id: "alb-1", name: "Dookie", mbid: "rg-1"),
      album_item(id: "alb-2", name: "Insomniac", mbid: "rg-2")
    ])
    stub_release_type("alb-2", "EP")

    adapter.resolve(tagged_track)

    insomniac = Rewind::Item.where(title: "Insomniac").first
    dookie = Rewind::Item.where(title: "Dookie").first

    assert_equal "ep", insomniac.metadata["release_type"] # normalized, cached
    # alb-1 has no plugin entry (default 404) — no type stored.
    assert_nil dookie.metadata["release_type"]
  end

  test "resolves an album to its release via the plugin fallback" do
    stub_album_tracks("alb-1", []) # the played track's own album backfill
    # Jellyfin's album payload carries the artist but not the release id.
    no_release = {
      "Id" => "alb-9", "Type" => "MusicAlbum", "Name" => "Kerplunk",
      "AlbumArtist" => "Green Day",
      "ProviderIds" => {"MusicBrainzAlbumArtist" => "art-1"}
    }
    stub_artist_albums("jf-artist-1", [no_release])
    # The plugin reads the release id from the album's file tags.
    WebMock.stub_request(:get, "https://jf.test/AudioMetadata/Album/alb-9")
           .to_return(
             status: 200, headers: {"Content-Type" => "application/json"},
             body: {
               "Tracks" => [
                 {
                   "ItemId" => "jf-k1",
                   "MusicBrainzAlbumId" => "rel-9",
                   "RawTags" => {"MUSICBRAINZ_ALBUMARTISTID" => "art-1"}
                 }
               ]
             }.to_json
           )

    adapter.resolve(tagged_track)

    kerplunk = Rewind::Item.where(title: "Kerplunk").first

    assert_equal "mbid:release:rel-9", kerplunk.external_id
    assert_equal "mbid:artist:art-1", kerplunk.parent_external_id
  end

  test "backfill_known_artists_albums fills a tracked artist's discography" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:art-1",
                         title: "Green Day")
    # One album we already have, carrying the Jellyfin id we read the artist's
    # own Jellyfin id from.
    create_item(media_type: "album", external_id: "mbid:release:rg-1",
                parent_external_id: artist.external_id, title: "Dookie",
                jellyfin_id: "alb-1")
    stub_item("alb-1", "Type" => "MusicAlbum", "Name" => "Dookie",
                       "AlbumArtists" => [
                         {
                           "Name" => "Green Day",
                           "Id" => "jf-artist-1"
                         }
                       ])
    stub_artist_albums("jf-artist-1", [
      album_item(id: "alb-1", name: "Dookie", mbid: "rg-1"),
      album_item(id: "alb-2", name: "Insomniac", mbid: "rg-2")
    ])
    stub_album_tracks("alb-1", [])
    stub_album_tracks("alb-2", [])

    count = adapter.backfill_known_artists_albums

    assert_equal 1, count
    albums = Rewind::Item.where(media_type: "album").order(:title)

    assert_equal %w[Dookie Insomniac], albums.map(:title)
    assert(albums.all? {|a| a.parent_external_id == artist.external_id })
  end

  test "an album with a release id resolves to mbid:release, not the group" do
    stub_album_tracks("alb-1", []) # the played track's own album backfill
    stub_artist_albums("jf-artist-1", [
      {
        "Id" => "alb-7", "Type" => "MusicAlbum", "Name" => "Kerplunk",
        "AlbumArtist" => "Green Day",
        "ProviderIds" => {
          "MusicBrainzAlbum" => "rel-7",
          "MusicBrainzReleaseGroup" => "rg-7",
          "MusicBrainzAlbumArtist" => "art-1"
        }
      }
    ])

    adapter.resolve(tagged_track)

    kerplunk = Rewind::Item.where(title: "Kerplunk").first

    assert_equal "mbid:release:rel-7", kerplunk.external_id
  end

  test "prune_orphaned_albums drops childless rg albums but keeps the rest" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:a",
                         title: "A")
    create_item(media_type: "album", external_id: "mbid:rg:dead",
                parent_external_id: artist.external_id, title: "Dead")
    create_item(media_type: "album", external_id: "mbid:rg:live",
                parent_external_id: artist.external_id, title: "Live")
    create_item(media_type: "track", external_id: "mbid:rec:1",
                parent_external_id: "mbid:rg:live", title: "T")
    create_item(media_type: "album", external_id: "mbid:release:keep",
                parent_external_id: artist.external_id, title: "Keep")

    removed = Rewind::Services::Sources::Jellyfin.prune_orphaned_albums

    assert_equal 1, removed
    assert_nil Rewind::Item.where(external_id: "mbid:rg:dead").first
    refute_nil Rewind::Item.where(external_id: "mbid:rg:live").first
    refute_nil Rewind::Item.where(external_id: "mbid:release:keep").first
  end

  test "backfill_known_artists_albums also creates each album's tracks" do
    artist = create_item(media_type: "artist",
                         external_id: "mbid:artist:art-1", title: "Green Day")
    create_item(media_type: "album", external_id: "mbid:release:rel-1",
                parent_external_id: artist.external_id, title: "Dookie",
                jellyfin_id: "alb-1")
    stub_item("alb-1", "Type" => "MusicAlbum", "Name" => "Dookie",
                       "AlbumArtists" => [
                         {
                           "Name" => "Green Day",
                           "Id" => "jf-artist-1"
                         }
                       ])
    stub_artist_albums("jf-artist-1",
                       [album_item(id: "alb-1", name: "Dookie", mbid: "rel-1")])
    stub_album_tracks("alb-1", [
      audio_item(id: "t1", name: "Burnout", index: 1).merge(
        "ProviderIds" => {
          "MusicBrainzTrack" => "rt-1",
          "MusicBrainzAlbum" => "rel-1",
          "MusicBrainzAlbumArtist" => "art-1"
        }
      )
    ])

    adapter.backfill_known_artists_albums

    track = Rewind::Item.where(media_type: "track", title: "Burnout").first

    refute_nil track
    assert_equal "mbid:rt:rt-1", track.external_id
    assert_equal "mbid:release:rel-1", track.parent_external_id
  end

  test "fetches an artist's albums at most once per run" do
    stub_album_tracks("alb-1", [])
    stub_artist_albums("jf-artist-1",
                       [album_item(id: "alb-1", name: "Dookie", mbid: "rg-1")])

    client = adapter
    client.resolve(tagged_track(id: "a1", name: "Burnout"))
    client.resolve(tagged_track(id: "a2", name: "Chump"))

    assert_requested(:get, %r{https://jf\.test/Users/u-1/Items},
                     times: 1,
                     query: hash_including("AlbumArtistIds" => "jf-artist-1"))
  end

  test "records a dateless audio track with no session as a null-dated play" do
    stub_items([
      {
        "Id" => "a9", "Type" => "Audio", "Name" => "Ghost Play",
        "Album" => "Nowhere", "AlbumArtist" => "Nobody",
        "UserData" => {"Played" => true}
      }
    ])

    result = adapter.recent_plays(since: nil)
    play = result[:plays].first

    # No session to date it, but the play still counts — just without a day.
    refute_nil play
    assert_nil play[:played_at]
    assert_equal "jellyfin:a9:played", play[:source_event_id]
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

  def audio_indexed(id:, name:, index:, at: nil)
    {
      "Id" => id, "Type" => "Audio", "Name" => name, "Album" => "Dookie",
      "AlbumArtist" => "Green Day", "ParentId" => "alb-1",
      "IndexNumber" => index,
      "UserData" => at ? {"LastPlayedDate" => at} : {"Played" => true}
    }
  end

  test "slots a dateless track between its dated neighbours by track number" do
    stub_album_tracks("alb-1", [])
    stub_items([
      audio_indexed(id: "t1", name: "One", index: 1,
                    at: "2026-10-18T20:00:00Z"),
      audio_indexed(id: "t3", name: "Three", index: 3,
                    at: "2026-10-18T20:06:00Z"),
      audio_indexed(id: "t2", name: "Two", index: 2)
    ])

    result = adapter.recent_plays(since: nil)
    two = Rewind::Item.where(title: "Two").first
    recovered = result[:plays].find {|p| p[:item_id] == two.id }

    refute_nil recovered
    # Track 2 lands halfway between track 1 (20:00) and track 3 (20:06).
    assert_equal Time.parse("2026-10-18T20:03:00Z"), recovered[:played_at]
    assert_equal "jellyfin:t2:played", recovered[:source_event_id]
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
