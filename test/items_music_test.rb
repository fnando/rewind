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

  test "track page shows the album year next to the album" do
    @album.update(release_date: "2007-10-10")

    get "/items/#{@track.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "(2007)"
  end

  test "the track page has no manual log button" do
    get "/items/#{@track.id}"

    refute_includes last_response.body, "Log a listen"
  end

  test "tracks cannot be logged manually" do
    post "/history", {item_id: @track.id}

    assert_equal 422, last_response.status
    assert_equal 0,
                 Rewind::Play.where(item_id: @track.id, source: "manual").count
  end

  test "album page lists its tracks" do
    get "/items/#{@album.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "OK Computer"
    assert_includes last_response.body, "/items/#{@track.id}"
  end

  test "album page offers a rating input and a review section" do
    get "/items/#{@album.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "/items/#{@album.id}/rating"
    assert_includes last_response.body, "/items/#{@album.id}/review"
    assert_includes last_response.body, "Your review"
  end

  test "an album can be rated and reviewed" do
    post "/items/#{@album.id}/rating", {rating: "4"}
    post "/items/#{@album.id}/review", {review: "A classic."}

    ui = Rewind::UserItem.where(user_id: @user.id, item_id: @album.id).first

    assert_equal 4, ui.rating
    assert_equal "A classic.", ui.review
  end

  test "album page orders tracks by track number, including unplayed ones" do
    create_item(
      media_type: "track", external_id: "mbid:t0", title: "Airbag",
      parent_external_id: "mbid:rg:r1", runtime: 4,
      metadata_json: {
        "album_external_id" => "mbid:rg:r1", "track_number" => 1
      }.to_json
    )
    # @track (Karma Police) is track 6.
    @track.update(metadata: @track.metadata.merge("track_number" => 6))

    get "/items/#{@album.id}"

    assert_equal 200, last_response.status
    # Unplayed track 1 (Airbag) sorts above played track 6 (Karma Police).
    assert_operator last_response.body.index("Airbag"), :<,
                    last_response.body.index("Karma Police")
    # Both appear in the tracklist, played or not.
    assert_includes last_response.body, "/items/#{@track.id}"
  end

  test "album page shows durations and totals from track length" do
    @track.update(metadata: @track.metadata.merge("length_ms" => 237_000))

    get "/items/#{@album.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "3:57"
    assert_includes last_response.body, "1 track play"
  end

  test "artist page lists its albums" do
    get "/items/#{@artist.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "/items/#{@album.id}"
  end

  test "history shows the track with links to its artist and album" do
    get "/history"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Karma Police"
    assert_includes last_response.body, "Radiohead"
    assert_includes last_response.body, "OK Computer"
    # artist and album names link to their item pages
    assert_includes last_response.body, %[href="/items/#{@artist.id}"]
    assert_includes last_response.body, %[href="/items/#{@album.id}"]
  end

  test "history does not collapse a lone track into an album group" do
    get "/history"

    assert_equal 200, last_response.status
    refute_includes last_response.body, "play-card--album"
  end

  test "history collapses consecutive tracks from one album into a group" do
    base = Time.now
    3.times do |i|
      track = create_item(
        media_type: "track", external_id: "mbid:extra:#{i}",
        title: "Extra #{i}", parent_external_id: "mbid:rg:r1", runtime: 4,
        metadata_json: {
          "artist" => "Radiohead", "artist_external_id" => "mbid:artist:a1",
          "album" => "OK Computer", "album_external_id" => "mbid:rg:r1"
        }.to_json
      )
      Rewind::Play.create(user_id: @user.id, item_id: track.id,
                          played_at: base + i, source: "jellyfin")
    end

    get "/history?type=track"

    assert_equal 200, last_response.status
    # The group renders a collapsing summary card with a track count...
    assert_includes last_response.body, "play-card--album"
    assert_includes last_response.body, "4 tracks"
    # ...and the individual tracks are present but hidden by default.
    assert_includes last_response.body, "data-album-tracks"
    assert_includes last_response.body, "play-card--in-album"
  end

  test "history has a music filter that lists only tracks" do
    movie = create_item(media_type: "movie", title: "Heat")
    Rewind::Play.create(user_id: @user.id, item_id: movie.id,
                        played_at: Time.now, source: "manual")

    get "/history?type=track"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Karma Police"
    refute_includes last_response.body, "Heat"
  end

  test "stats page renders with the music filter" do
    get "/stats?type=music"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Radiohead"
  end

  test "stats all view renders a time-weighted donut with a music segment" do
    movie = create_item(media_type: "movie", title: "Heat", runtime: 170)
    Rewind::Play.create(user_id: @user.id, item_id: movie.id,
                        played_at: Time.now, source: "manual")

    get "/stats"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "donut__seg--music"
    assert_includes last_response.body, "1 track"
  end
end
