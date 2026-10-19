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

  test "sync runs a sync immediately" do
    stub_tmdb_movie(27_205)
    stub_items([movie_item(id: "m1", last_played: "2026-10-16T05:00:00Z")])

    out, = capture_io { Rewind::CLI.start(["sync", "--no-verbose"]) }

    assert_equal 1, Rewind::Play.count
    assert_match(/Synced 1 source/, out)
  end

  test "sync --reset re-pulls without deleting existing plays or ratings" do
    # Accumulated history Jellyfin no longer exposes must survive a --reset.
    old = create_item(media_type: "movie", external_id: "tmdb:999",
                      title: "Old")
    old_play = Rewind::Play.create(
      user_id: @user.id, item_id: old.id, source: "jellyfin",
      source_event_id: "jellyfin:old:x", played_at: Time.now
    )
    Rewind::UserItem.create(user_id: @user.id, item_key: old.rating_key,
                            rating: 5)

    stub_tmdb_movie(27_205)
    stub_items([movie_item(id: "m1", last_played: "2026-10-16T05:00:00Z")])

    out, = capture_io do
      Rewind::CLI.start(["sync", "--reset", "--no-verbose"])
    end

    # Nothing deleted: the old play/item stay, the fresh one is added on top.
    refute_nil Rewind::Play[old_play.id]
    refute_nil Rewind::Item.where(external_id: "tmdb:999").first
    refute_nil Rewind::Item.where(external_id: "tmdb:27205").first
    assert_equal 2, Rewind::Play.count
    assert_equal 1, Rewind::UserItem.count
    assert_match(/Nothing was deleted/, out)
  end

  test "sync aborts when there are no enabled sources" do
    @source.update(enabled: false)

    assert_raises(SystemExit) do
      capture_io { Rewind::CLI.start(["sync", "--no-verbose"]) }
    end
  end
end
