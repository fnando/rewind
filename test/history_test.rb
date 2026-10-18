# frozen_string_literal: true

require "test_helper"

class HistoryTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)
  end

  def create_plays(count, media_type: "movie")
    base = Time.now
    Array.new(count) do |i|
      item = create_item(media_type:, title: "Item #{i}")
      Rewind::Play.create(user_id: @user.id, item_id: item.id,
                          played_at: base - i, source: "manual")
    end
  end

  test "no pagination nav when plays fit on one page" do
    create_plays(3)

    get "/history"

    assert_equal 200, last_response.status
    refute_includes last_response.body, "pagination"
  end

  test "first page shows Older link but no Newer link" do
    create_plays(Rewind::Application::PLAYS_PER_PAGE + 1)

    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, ">Older</a>"
    refute_includes last_response.body, ">Newer</a>"
    assert_includes last_response.body, %[href="/history?page=2"]
  end

  test "second page shows Newer link and the oldest play" do
    plays = create_plays(Rewind::Application::PLAYS_PER_PAGE + 1)
    oldest = plays.last

    get "/history?page=2"

    assert_equal 200, last_response.status
    assert_includes last_response.body, ">Newer</a>"
    refute_includes last_response.body, ">Older</a>"
    assert_includes last_response.body, %[href="/items/#{oldest.item_id}"]
  end

  test "pagination preserves the media type filter" do
    create_plays(Rewind::Application::PLAYS_PER_PAGE + 1, media_type: "track")

    get "/history?type=track"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "type=track"
    assert_includes last_response.body, "page=2"
  end
end
