# frozen_string_literal: true

require "test_helper"
require "time"

class JellyfinArchiveTest < Minitest::Test
  Archive = Rewind::Services::JellyfinArchive
  INSTANCE = "srv-1"

  def setup
    @user = create_user
  end

  def track(external_id, jellyfin_id:, title: "The Thief")
    create_item(media_type: "track", external_id:, jellyfin_id:, title:,
                metadata_json: {}.to_json)
  end

  def remember(jellyfin_id, item, recording: nil, media_type: "track")
    Archive.remember(item:, jellyfin_id:, media_type:,
                     instance_id: INSTANCE, recording_mbid: recording)
  end

  def play_on(item, at: "2026-10-10 12:00:00 UTC", event: "e1")
    Rewind::Play.create(user_id: @user.id, item_id: item.id, source: "jellyfin",
                        instance_id: INSTANCE, source_event_id: event,
                        played_at: Time.parse(at))
  end

  # A client whose item_present? answers the same tri-state for every id.
  def client(answer)
    stub = Object.new
    stub.define_singleton_method(:item_present?) {|**| answer }
    stub
  end

  def reconcile(target, client:, recording: "rec-1")
    Archive.reconcile(target:, recording_mbid: recording, instance_id: INSTANCE,
                      user_id: "u", client:)
  end

  test "remember upserts idempotently and keeps the first recording" do
    item = track("mbid:rt:1", jellyfin_id: "jf-1")
    remember("jf-1", item, recording: "rec-1")
    remember("jf-1", item, recording: nil) # a later ids-only sighting

    rows = Rewind.db[:jellyfin_seen].where(jellyfin_id: "jf-1").all

    assert_equal 1, rows.size
    assert_equal item.id, rows.first[:item_id]
    assert_equal "rec-1", rows.first[:recording_mbid]
    assert Archive.seen?("jf-1", INSTANCE)
    refute Archive.seen?("jf-1", "other-instance")
  end

  test "reconcile moves a stranded play onto the new row when old id is gone" do
    old = track("mbid:rt:apathetic", jellyfin_id: "jf-old")
    play_on(old)
    remember("jf-old", old, recording: "rec-1")
    fresh = track("mbid:rt:mmhmm", jellyfin_id: "jf-new")

    absorbed = reconcile(fresh, client: client(false))

    assert_equal old.id, absorbed
    assert_nil Rewind::Item[old.id]
    assert_equal 1, Rewind::Play.where(item_id: fresh.id).count
    assert_equal 0, Rewind::Play.where(item_id: old.id).count
    # The ledger now points the old id at the surviving row.
    assert_equal fresh.id,
                 Rewind.db[:jellyfin_seen].where(jellyfin_id: "jf-old")
                       .get(:item_id)
    assert_empty Rewind::Services::Streaks.verify(@user)
  end

  test "reconcile carries a rating across when the old id died" do
    old = track("mbid:rt:apathetic", jellyfin_id: "jf-old")
    play_on(old)
    Rewind::UserItem.create(user_id: @user.id, item_key: old.rating_key,
                            rating: 5)
    remember("jf-old", old, recording: "rec-1")
    fresh = track("mbid:rt:mmhmm", jellyfin_id: "jf-new")

    reconcile(fresh, client: client(false))

    assert_equal 5,
                 Rewind::UserItem.where(user_id: @user.id,
                                        item_key: fresh.rating_key).get(:rating)
  end

  test "reconcile leaves both rows alone when the old id is still alive" do
    old = track("mbid:rt:apathetic", jellyfin_id: "jf-old")
    play_on(old)
    remember("jf-old", old, recording: "rec-1")
    fresh = track("mbid:rt:mmhmm", jellyfin_id: "jf-new")

    assert_nil reconcile(fresh, client: client(true))
    refute_nil Rewind::Item[old.id]
    assert_equal 1, Rewind::Play.where(item_id: old.id).count
  end

  test "reconcile never merges on an unknown (transient) staleness answer" do
    old = track("mbid:rt:apathetic", jellyfin_id: "jf-old")
    play_on(old)
    remember("jf-old", old, recording: "rec-1")
    fresh = track("mbid:rt:mmhmm", jellyfin_id: "jf-new")

    assert_nil reconcile(fresh, client: client(:unknown))
    refute_nil Rewind::Item[old.id]
  end

  test "reconcile skips when two dead rows share the recording (ambiguous)" do
    one = track("mbid:rt:a", jellyfin_id: "jf-a")
    two = track("mbid:rt:b", jellyfin_id: "jf-b")
    play_on(one, event: "e1")
    play_on(two, event: "e2")
    remember("jf-a", one, recording: "rec-1")
    remember("jf-b", two, recording: "rec-1")
    fresh = track("mbid:rt:mmhmm", jellyfin_id: "jf-new")

    assert_nil reconcile(fresh, client: client(false))
    refute_nil Rewind::Item[one.id]
    refute_nil Rewind::Item[two.id]
  end

  test "reconcile ignores an unplayed, unrated twin (nothing to preserve)" do
    old = track("mbid:rt:apathetic", jellyfin_id: "jf-old")
    remember("jf-old", old, recording: "rec-1")
    fresh = track("mbid:rt:mmhmm", jellyfin_id: "jf-new")

    assert_nil reconcile(fresh, client: client(false))
    refute_nil Rewind::Item[old.id]
  end

  test "reconcile is a no-op without a recording or instance" do
    old = track("mbid:rt:apathetic", jellyfin_id: "jf-old")
    play_on(old)
    remember("jf-old", old, recording: "rec-1")
    fresh = track("mbid:rt:mmhmm", jellyfin_id: "jf-new")

    assert_nil reconcile(fresh, client: client(false), recording: nil)
    assert_nil Archive.reconcile(target: fresh, recording_mbid: "rec-1",
                                 instance_id: nil, user_id: "u",
                                 client: client(false))
    refute_nil Rewind::Item[old.id]
  end
end
