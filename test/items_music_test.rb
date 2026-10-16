# frozen_string_literal: true

require "test_helper"

class ItemsMusicTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)

    @artist = create_item(media_type: "artist", external_id: "mbid:artist:a1",
                          title: "Radiohead")
    @album = create_item(
      media_type: "album", external_id: "mbid:rg:r1", title: "OK Computer",
      parent_external_id: "mbid:artist:a1", poster_path: "https://art/r1.jpg"
    )
    @track = create_item(
      media_type: "track", external_id: "mbid:t1", title: "Karma Police",
      parent_external_id: "mbid:rg:r1", runtime: 4,
      metadata_json: {
        "artist" => "Radiohead", "artist_external_id" => "mbid:artist:a1",
        "album" => "OK Computer", "album_external_id" => "mbid:rg:r1"
      }.to_json
    )
    Rewind::Play.create(user_id: @user.id, item_id: @track.id,
                        played_at: Time.now, source: "jellyfin")
  end

  test "track page renders with artist and album links" do
    get "/items/#{@track.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Karma Police"
    assert_includes last_response.body, "/items/#{@album.id}"
    assert_includes last_response.body, "/items/#{@artist.id}"
  end

  test "album page lists its tracks" do
    get "/items/#{@album.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "OK Computer"
    assert_includes last_response.body, "/items/#{@track.id}"
  end

  test "artist page lists its albums" do
    get "/items/#{@artist.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "/items/#{@album.id}"
  end

  test "history shows the track with artist and album" do
    get "/plays"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Karma Police"
    assert_includes last_response.body, "Radiohead"
    assert_includes last_response.body, "OK Computer"
  end

  test "history has a music filter that lists only tracks" do
    movie = create_item(media_type: "movie", title: "Heat")
    Rewind::Play.create(user_id: @user.id, item_id: movie.id,
                        played_at: Time.now, source: "manual")

    get "/plays?type=track"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Karma Police"
    refute_includes last_response.body, "Heat"
  end

  test "stats page renders with the music filter" do
    get "/stats?type=music"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Radiohead"
  end
end
