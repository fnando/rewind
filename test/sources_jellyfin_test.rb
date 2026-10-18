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
    Rewind.logger.level = Logger::INFO

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
