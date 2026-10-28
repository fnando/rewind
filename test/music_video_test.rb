# frozen_string_literal: true

require "test_helper"

class MusicVideoServiceTest < Minitest::Test
  def setup
    @artist = create_item(media_type: "artist", external_id: "mbid:artist:a1",
                          title: "Green Day")
  end

  def build(name)
    Rewind::Services::MusicVideo.build(
      external_id: "youtube:v1", title: "Basket Case", artist_name: name,
      runtime: 3, release_date: "1994-01-01", jellyfin_id: "jf-1"
    )
  end

  test "artist_item_for matches an artist by a normalized title" do
    found = Rewind::Services::MusicVideo.artist_item_for("  green DAY ")

    assert_equal @artist.id, found&.id
  end

  test "artist_item_for returns nil for a blank or unknown name" do
    assert_nil Rewind::Services::MusicVideo.artist_item_for("")
    assert_nil Rewind::Services::MusicVideo.artist_item_for("Nobody")
  end

  test "build links a music video to its matching artist" do
    video = build("Green Day")

    assert_equal "music_video", video.media_type
    assert_equal "youtube:v1", video.external_id
    assert_equal @artist.external_id, video.parent_external_id
    assert_equal @artist.external_id, video.metadata["artist_external_id"]
    assert_equal "Green Day", video.metadata["artist"]
    assert_equal "jf-1", video.jellyfin_id
    assert_equal 3, video.runtime
  end

  test "build keeps an unmatched artist as text only" do
    video = build("Some Other Band")

    assert_nil video.parent_external_id
    assert_nil video.metadata["artist_external_id"]
    assert_equal "Some Other Band", video.metadata["artist"]
  end

  test "build upserts on (media_type, external_id)" do
    first = build("Green Day")
    second = build("Green Day")

    assert_equal first.id, second.id
    assert_equal 1, Rewind::Item.where(media_type: "music_video").count
  end
end
