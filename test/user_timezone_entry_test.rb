# frozen_string_literal: true

require "test_helper"

class UserTimezoneEntryTest < Minitest::Test
  def setup
    @user = create_user
    @user.update(timezone: "America/Los_Angeles")
  end

  def play_at(time)
    item = create_item(media_type: "movie")
    Rewind::Play.create(user_id: @user.id, item_id: item.id,
                        played_at: time, source: "manual")
  end

  test "a play freezes the local day it happened in" do
    # 02:00 UTC on Jan 10 is still Jan 9 (18:00) in PST.
    play = play_at(Time.utc(2026, 1, 10, 2, 0))

    assert_equal "2026-01-09", play.local_date
    entry = play.user_timezone_entry

    assert_equal "America/Los_Angeles", entry.name
    assert_equal(-28_800, entry.offset) # PST, -8h
  end

  test "changing the timezone does not rewrite existing plays" do
    play = play_at(Time.utc(2026, 1, 10, 2, 0))
    frozen_date = play.local_date
    frozen_entry_id = play.user_timezone_entry_id

    @user.update(timezone: "America/Sao_Paulo")
    play.refresh

    assert_equal frozen_date, play.local_date
    assert_equal frozen_entry_id, play.user_timezone_entry_id

    # Only new plays pick up the new zone.
    later = play_at(Time.utc(2026, 1, 11, 2, 0))

    assert_equal "America/Sao_Paulo", later.user_timezone_entry.name
    assert_equal "2026-01-10", later.local_date # UTC-3 -> still Jan 10 23:00
  end

  test "the same zone across a DST boundary yields distinct entries" do
    winter = play_at(Time.utc(2026, 1, 15, 20, 0)) # PST, -8h
    summer = play_at(Time.utc(2026, 7, 15, 20, 0)) # PDT, -7h

    refute_equal winter.user_timezone_entry_id, summer.user_timezone_entry_id
    assert_equal(-28_800, winter.user_timezone_entry.offset)
    assert_equal(-25_200, summer.user_timezone_entry.offset)
    assert_equal 2, Rewind::UserTimezoneEntry.where(user_id: @user.id).count
  end

  test "repeated plays in the same context reuse one entry" do
    a = play_at(Time.utc(2026, 1, 15, 20, 0))
    b = play_at(Time.utc(2026, 1, 16, 20, 0))

    assert_equal a.user_timezone_entry_id, b.user_timezone_entry_id
    assert_equal 1, Rewind::UserTimezoneEntry.where(user_id: @user.id).count
  end

  test "an undated play carries no entry or local_date" do
    item = create_item(media_type: "movie")
    play = Rewind::Play.create(user_id: @user.id, item_id: item.id,
                               played_at: nil, source: "jellyfin")

    assert_nil play.local_date
    assert_nil play.user_timezone_entry_id
  end
end
