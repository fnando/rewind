# frozen_string_literal: true

require "test_helper"

class SyncTest < Minitest::Test
  def setup
    @user = create_user
    @source = create_source(user_id: @user.id, url: "https://jf.test",
                            external_user_id: "u-1", access_token: "tok")
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

  def movie_item(id:, last_played:)
    {
      "Id" => id, "Type" => "Movie", "Name" => "Inception",
      "ProviderIds" => {"Tmdb" => "27205"},
      "UserData" => {"LastPlayedDate" => last_played}
    }
  end

  test "run_once records plays and advances the cursor" do
    stub_tmdb_movie(27_205)
    stub_items([movie_item(id: "m1", last_played: "2026-10-16T05:00:00Z")])

    Rewind::Services::Sync.run_once

    assert_equal 1, Rewind::Play.count
    play = Rewind::Play.first

    assert_equal "jellyfin", play.source
    assert_equal @source.id, play.source_id
    assert_equal "2026-10-16T05:00:00Z", @source.refresh.cursor
    refute_nil @source.refresh.last_synced_at
  end

  test "run_once is idempotent across runs" do
    stub_tmdb_movie(27_205)
    stub_items([movie_item(id: "m1", last_played: "2026-10-16T05:00:00Z")])

    Rewind::Services::Sync.run_once
    Rewind::Services::Sync.run_once

    assert_equal 1, Rewind::Play.count
  end

  test "recording the same source event twice keeps a single play" do
    item = create_item(media_type: "movie")
    play = {
      item_id: item.id, played_at: Time.now,
      source_event_id: "jellyfin:m1:2026-10-16T05:00:00Z"
    }

    Rewind::Services::Sync.record_play(@source, play)
    Rewind::Services::Sync.record_play(@source, play)

    assert_equal 1, Rewind::Play.count
  end

  test "an unauthorized response disables the source" do
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .to_return(status: 401)

    Rewind::Services::Sync.run_once

    refute @source.refresh.enabled?
  end

  test "a disabled source is skipped" do
    @source.update(enabled: false)
    Rewind::Services::Sync.run_once

    assert_equal 0, Rewind::Play.count
  end
end
