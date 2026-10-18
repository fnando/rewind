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

  test "logs items it can't match so skips are visible with --verbose" do
    stub_items([
      {
        "Id" => "yt1", "Type" => "Movie", "Name" => "A YouTube Video",
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
    assert_includes io.string, %[skipped Movie "A YouTube Video" (yt1)]
    assert_includes io.string, "no TMDB/MusicBrainz match"
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
