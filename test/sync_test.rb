# frozen_string_literal: true

require "test_helper"

class SyncTest < Minitest::Test
  CHANGES = %r{https://jf\.test/Rewind/History/Changes}

  def setup
    @user = create_user
    @source = create_source(user_id: @user.id, url: "https://jf.test",
                            external_user_id: "u-1", access_token: "tok")
    WebMock.stub_request(:get, %r{https://jf\.test/AudioMetadata/Album/})
           .to_return(status: 404)
    WebMock.stub_request(:get, "https://jf.test/Users/Me")
           .to_return(status: 404)
  end

  def json(body)
    {
      status: 200, body: body.to_json,
      headers: {"Content-Type" => "application/json"}
    }
  end

  # Stubs the plugin's changes feed. Each page is a list of entries; pages are
  # served in order, keyed on the `since` they answer.
  def stub_changes(*pages, start: 0)
    since = start
    pages.each_with_index do |entries, index|
      next_since = entries.filter_map { it["seq"] }.max || since
      WebMock.stub_request(:get, CHANGES)
             .with(query: hash_including("since" => since.to_s))
             .to_return(json("items" => entries, "nextSince" => next_since,
                             "hasMore" => index < pages.size - 1))
      since = next_since
    end
  end

  def stub_library_item(item)
    WebMock.stub_request(:get,
                         %r{https://jf\.test/Users/u-1/Items/#{item['Id']}\?})
           .to_return(json(item))
  end

  def stub_item_gone(id)
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items/#{id}\?})
           .to_return(status: 404)
  end

  def movie_item(id: "m1")
    {
      "Id" => id, "Type" => "Movie", "Name" => "Inception",
      "ProviderIds" => {"Tmdb" => "27205"}
    }
  end

  def entry(seq:, id: "p1", item_id: "m1", **attrs)
    {
      "id" => id, "seq" => seq, "itemId" => item_id, "itemType" => "Movie",
      "name" => "Inception", "startedAt" => "2026-10-16T05:00:00Z",
      "status" => "completed", "source" => "playback", "scrobbled" => true
    }.merge(attrs.transform_keys(&:to_s))
  end

  def sync
    Rewind::Services::Sync.sync_source(@source)
  end

  test "records a scrobble at its start time and advances the cursor" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 7)])

    Rewind::Services::Sync.run_once

    play = Rewind::Play.first

    assert_equal 1, Rewind::Play.count
    assert_equal "jellyfin", play.source
    assert_equal @source.id, play.source_id
    assert_equal @source.instance_id, play.instance_id
    assert_equal "rewind:p1", play.source_event_id
    assert_equal Time.parse("2026-10-16T05:00:00Z"), play.played_at
    assert_equal "tmdb:27205", play.item.external_id
    assert_equal "7", @source.refresh.cursor
    refute_nil @source.refresh.last_synced_at
  end

  test "sends the stored cursor as since" do
    @source.this.update(cursor: "41")
    @source.refresh
    stub_changes([], start: 41)

    sync

    assert_requested(:get, CHANGES, query: hash_including("since" => "41"))
    assert_equal "41", @source.refresh.cursor
  end

  test "re-delivering an entry keeps a single play" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1), entry(seq: 2)])

    sync

    assert_equal 1, Rewind::Play.count
  end

  test "a play still under the scrobble rules is skipped until it counts" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([
      entry(seq: 1, status: "active", scrobbled: false),
      entry(seq: 2, status: "active", scrobbled: true),
      entry(seq: 3, status: "completed", scrobbled: true)
    ])

    sync

    assert_equal 1, Rewind::Play.count
  end

  test "a detail change on a recorded play is a no-op" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1)])
    sync
    play = Rewind::Play.first

    stub_changes([entry(seq: 2, genres: ["Sci-Fi"])], start: 1)
    sync

    assert_equal [play.id], Rewind::Play.select_map(:id)
    assert_equal "2", @source.refresh.cursor
  end

  test "a deleted entry removes only its own play" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1, id: "p1"), entry(seq: 2, id: "p2")])
    sync
    rating = Rewind::UserItem.create(user_id: @user.id,
                                     item_key: Rewind::Play.first.item
                                                           .rating_key,
                                     rating: 5)

    stub_changes([entry(seq: 3, id: "p1", deleted: true)], start: 2)
    sync

    assert_equal ["rewind:p2"], Rewind::Play.select_map(:source_event_id)
    refute_nil Rewind::UserItem[rating.id]
  end

  test "an un-scrobble removes the play and a re-scrobble restores it" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1)])
    sync

    stub_changes([entry(seq: 2, scrobbled: false)], start: 1)
    sync

    assert_equal 0, Rewind::Play.count

    stub_changes([entry(seq: 3, scrobbled: true)], start: 2)
    sync

    assert_equal ["rewind:p1"], Rewind::Play.select_map(:source_event_id)
  end

  test "imports plays the user marked as played" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1, source: "manual")])

    sync

    assert_equal 1, Rewind::Play.count
  end

  test "pages through the feed while it has more, saving each cursor" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1, id: "p1")], [entry(seq: 2, id: "p2")])

    sync

    assert_equal 2, Rewind::Play.count
    assert_equal "2", @source.refresh.cursor
  end

  test "an item gone from the library falls back to its stamped item" do
    known = create_item(media_type: "movie", jellyfin_id: "m1")
    stub_item_gone("m1")
    stub_changes([entry(seq: 1)])

    sync

    assert_equal known.id, Rewind::Play.first.item_id
  end

  test "an item gone from the library resolves from the plugin snapshot" do
    stub_tmdb_movie(27_205)
    stub_item_gone("m1")
    stub_changes([entry(seq: 1, providerIds: {"Tmdb" => "27205"})])

    sync

    assert_equal "tmdb:27205", Rewind::Play.first.item.external_id
  end

  test "a gone track resolves from its snapshotted MusicBrainz ids" do
    stub_item_gone("a1")
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items\?})
           .to_return(json("Items" => []))
    stub_changes([
      entry(seq: 1, item_id: "a1", itemType: "Audio", name: "Burnout",
            album: "Dookie", albumId: "alb-1", albumArtists: ["Green Day"],
            indexNumber: 3, discNumber: 1,
            providerIds: {
              "MusicBrainzTrack" => "rt-1",
              "MusicBrainzAlbum" => "rel-1",
              "MusicBrainzAlbumArtist" => "art-1"
            })
    ])

    sync
    track = Rewind::Play.first.item

    assert_equal "mbid:rt:rt-1", track.external_id
    assert_equal "mbid:release:rel-1", track.parent_external_id
    assert_equal "Green Day", track.artist
  end

  test "an unmatched scrobble is skipped and logged on the errors page" do
    stub_library_item("Id" => "a1", "Type" => "Audio")
    stub_changes([entry(seq: 1, item_id: "a1", itemType: "Audio", name: nil)])

    sync

    assert_equal 0, Rewind::Play.count
    assert_equal "1", @source.refresh.cursor
    assert_match(/Unmatched play/, Rewind::ErrorLog.first.message)
  end

  test "a failure fetching the item holds the cursor for a retry" do
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items/m1\?})
           .to_return(status: 500)
    stub_changes([entry(seq: 1)])

    Rewind::Services::Sync.run_once

    assert_equal 0, Rewind::Play.count
    assert_nil @source.refresh.cursor
    refute_nil @source.refresh.last_error_id
  end

  test "a server without the plugin records a clear error" do
    WebMock.stub_request(:get, CHANGES).to_return(status: 404)

    Rewind::Services::Sync.run_once

    error = Rewind::SourceError[@source.refresh.last_error_id]

    assert_match(/Rewind plugin not installed/, error.message)
  end

  test "an unauthorized response leaves the source enabled and logs it" do
    WebMock.stub_request(:get, CHANGES).to_return(status: 401)

    Rewind::Services::Sync.run_once

    assert @source.refresh.enabled?
    assert_equal 1, Rewind::SourceError.where(source_id: @source.id).count
  end

  test "a successful sync clears the pointer but keeps the error log" do
    err_id = Rewind.db[:source_errors].insert(
      source_id: @source.id, message: "boom", created_at: Time.now
    )
    Rewind.db[:sources].where(id: @source.id).update(last_error_id: err_id)
    stub_changes([])

    Rewind::Services::Sync.run_once

    assert_nil @source.refresh.last_error_id
    assert_equal 1, Rewind::SourceError.where(source_id: @source.id).count
  end

  test "a source without an instance id adopts the server's id first" do
    Rewind.db[:sources].where(id: @source.id).update(instance_id: nil)
    @source.refresh
    WebMock.stub_request(:get, "https://jf.test/System/Info/Public")
           .to_return(json("Id" => "srv-77"))
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1)])

    sync

    assert_equal "srv-77", @source.refresh.instance_id
    assert_equal "srv-77", Rewind::Play.first.instance_id
  end

  test "a source without a username learns it on the next sync" do
    WebMock.stub_request(:get, "https://jf.test/Users/Me")
           .to_return(json("Id" => "u-1", "Name" => "fnando"))
    stub_changes([])

    sync

    assert_equal "fnando", @source.refresh.external_user_name
  end

  test "a renamed Jellyfin user shows the new name after a sync" do
    @source.this.update(external_user_name: "old-name")
    WebMock.stub_request(:get, "https://jf.test/Users/Me")
           .to_return(json("Id" => "u-1", "Name" => "new-name"))
    stub_changes([])

    sync

    assert_equal "new-name", @source.refresh.external_user_name
  end

  test "a username that can't be read doesn't stop the sync" do
    @source.this.update(external_user_name: "fnando")
    WebMock.stub_request(:get, "https://jf.test/Users/Me")
           .to_return(status: 500)
    stub_changes([])

    sync

    assert_equal "fnando", @source.refresh.external_user_name
    assert_nil @source.last_error_id
  end

  test "two accounts on the same server keep their own plays" do
    other_user = create_user
    other = create_source(user_id: other_user.id, url: "https://jf.test",
                          external_user_id: "u-1", access_token: "tok2",
                          instance_id: @source.instance_id)
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1)])

    sync
    Rewind::Services::Sync.sync_source(other)

    assert_equal [@user.id, other_user.id].sort,
                 Rewind::Play.select_map(:user_id).sort
  end

  test "a disabled source is skipped" do
    @source.update(enabled: false)
    Rewind::Services::Sync.run_once

    assert_not_requested(:get, CHANGES)
  end

  test "sync runs a sync immediately" do
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1)])

    out, = capture_io { Rewind::CLI.start(["sync", "--no-verbose"]) }

    assert_equal 1, Rewind::Play.count
    assert_match(/Synced 1 source/, out)
  end

  test "sync --reset replaces the Jellyfin plays and keeps everything else" do
    old = create_item(media_type: "movie", external_id: "tmdb:999",
                      title: "Old")
    pulled = Rewind::Play.create(
      user_id: @user.id, item_id: old.id, source: "jellyfin",
      source_id: @source.id, instance_id: @source.instance_id,
      source_event_id: "jellyfin:old:x", played_at: Time.now
    )
    webhook = Rewind::Play.create(
      user_id: @user.id, item_id: old.id, source: "jellyfin",
      source_id: nil, instance_id: @source.instance_id,
      source_event_id: "jellyfin:old:y", played_at: Time.now
    )
    trakt = Rewind::Play.create(user_id: @user.id, item_id: old.id,
                                source: "trakt", played_at: Time.now)
    Rewind::UserItem.create(user_id: @user.id, item_key: old.rating_key,
                            rating: 5)
    @source.this.update(cursor: "99")
    stub_tmdb_movie(27_205)
    stub_library_item(movie_item)
    stub_changes([entry(seq: 1)])

    out, = capture_io do
      Rewind::CLI.start(["sync", "--reset", "--yes", "--no-verbose"])
    end

    assert_nil Rewind::Play[pulled.id]
    assert_nil Rewind::Play[webhook.id]
    refute_nil Rewind::Play[trakt.id]
    assert_equal ["rewind:p1"],
                 Rewind::Play.where(source: "jellyfin")
                             .select_map(:source_event_id)
    assert_equal 1, Rewind::UserItem.count
    refute_nil Rewind::Item.where(external_id: "tmdb:999").first
    assert_match(/Removed 2 and imported 1 plays/, out)
  end

  test "sync --reset leaves another account's plays on the same server" do
    other_user = create_user
    other = create_source(user_id: other_user.id, url: "https://jf.test",
                          external_user_id: "u-2",
                          instance_id: @source.instance_id)
    item = create_item(media_type: "movie")
    theirs = Rewind::Play.create(
      user_id: other_user.id, item_id: item.id, source: "jellyfin",
      source_id: other.id, instance_id: other.instance_id,
      source_event_id: "rewind:theirs", played_at: Time.now
    )

    removed = Rewind::Services::Sync.reset([@source])

    assert_equal 0, removed
    refute_nil Rewind::Play[theirs.id]
  end

  test "sync aborts when there are no enabled sources" do
    @source.update(enabled: false)

    assert_raises(SystemExit) do
      capture_io { Rewind::CLI.start(["sync", "--no-verbose"]) }
    end
  end

  # --- Locked-write resilience ---------------------------------------------

  def locked_error
    Sequel::DatabaseError.new("SQLite3::BusyException: database is locked")
  end

  def fake_adapter(item)
    adapter = Object.new
    adapter.define_singleton_method(:resolve_entry) {|_entry| item }
    adapter
  end

  test "record_entry defers a locked write instead of raising" do
    adapter = fake_adapter(create_item(media_type: "movie"))
    Rewind::Play.stubs(:create).raises(locked_error)

    outcome = Rewind::Services::Sync.record_entry(@source, adapter,
                                                  entry(seq: 1))

    assert_equal :deferred, outcome
    assert_equal 0, Rewind::Play.count
  end

  test "record_entry re-raises a non-lock database error" do
    adapter = fake_adapter(create_item(media_type: "movie"))
    Rewind::Play.stubs(:create).raises(Sequel::DatabaseError, "disk I/O error")

    assert_raises(Sequel::DatabaseError) do
      Rewind::Services::Sync.record_entry(@source, adapter, entry(seq: 1))
    end
  end

  test "a deferred entry holds the cursor and still attempts the whole page" do
    stub_changes([entry(seq: 1, id: "a"), entry(seq: 2, id: "b")])
    # First write lands, second is deferred by a lock. Expecting exactly two
    # calls proves the lock didn't skip the rest of the page.
    Rewind::Services::Sync.expects(:record_entry).twice
                          .returns(:written, :deferred)

    sync

    assert_nil @source.refresh.cursor
    refute_nil @source.refresh.last_error_id
  end
end
