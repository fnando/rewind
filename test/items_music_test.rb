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

    ui = Rewind::UserItem.where(user_id: @user.id,
                                item_key: @album.rating_key).first

    assert_equal 4, ui.rating
    assert_equal "A classic.", ui.review
  end

  test "an album rating survives a re-tag that changes its mbid" do
    @album.update(jellyfin_id: "jf-album-1")
    post "/items/#{@album.id}/rating", {rating: "5"}

    # Re-tag in Jellyfin -> a fresh album row, new mbid, same jellyfin id.
    retagged = create_item(media_type: "album", external_id: "mbid:rg:new",
                           title: "OK Computer", jellyfin_id: "jf-album-1")
    get "/items/#{retagged.id}"

    assert_equal 200, last_response.status
    # The 5-star rating is found for the new row via the shared jellyfin id.
    assert_includes last_response.body,
                    'value="5" aria-label="5 stars" aria-pressed="true"'
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
    assert_includes last_response.body, "title-hero__poster--square"
    # Artists can be rated and reviewed like any other item.
    assert_includes last_response.body, "/items/#{@artist.id}/rating"
    assert_includes last_response.body, "/items/#{@artist.id}/review"
  end

  test "artist page lists albums newest first" do
    @album.update(release_date: "1997-05-21") # OK Computer
    newer = create_item(media_type: "album", external_id: "mbid:rg:ir",
                        title: "In Rainbows", release_date: "2007-10-10",
                        parent_external_id: @artist.external_id)

    get "/items/#{@artist.id}"

    assert_operator last_response.body.index("/items/#{newer.id}"), :<,
                    last_response.body.index("/items/#{@album.id}")
  end

  test "artist page shows a flat list when no release type is known" do
    get "/items/#{@artist.id}"

    assert_includes last_response.body, ">Albums</h2>"
    refute_includes last_response.body, ">Releases</h2>"
  end

  test "artist page groups albums into sections by release type" do
    @album.update(metadata: @album.metadata.merge("release_type" => "album"))
    create_item(media_type: "album", external_id: "mbid:rg:ep1",
                title: "Airbag", parent_external_id: @artist.external_id,
                metadata_json: {"release_type" => "ep"}.to_json)

    get "/items/#{@artist.id}"

    # Each release type is its own section heading.
    assert_includes last_response.body, ">Albums</h2>"
    assert_includes last_response.body, ">EPs</h2>"
  end

  test "artist page albums use the history cover-card design" do
    @album.update(release_date: "1997-05-21")

    get "/items/#{@artist.id}"

    # Same shell as the History album card: a square cover card with the Album
    # badge, a title link, the year, and an on-cover rating control.
    assert_includes last_response.body, "cover-card cover-card--track"
    assert_includes last_response.body, ">Album</span>"
    assert_includes last_response.body,
                    %[<a class="cover-card__title" href="/items/#{@album.id}">]
    assert_includes last_response.body, "1997"
    assert_includes last_response.body, "on-cover"
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
    refute_includes last_response.body, "cover-card--group"
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
    assert_includes last_response.body, "cover-card--group"
    assert_includes last_response.body, "4 tracks"
    # ...and the individual tracks are present but hidden by default.
    assert_includes last_response.body, "data-album-tracks"
    assert_includes last_response.body, "cover-card--in-album"
  end

  test "an album group card carries the album's rating" do
    # A second track from the same album forms a collapsible group.
    track = create_item(
      media_type: "track", external_id: "mbid:t2", title: "No Surprises",
      parent_external_id: "mbid:rg:r1", runtime: 4,
      metadata_json: {
        "artist" => "Radiohead", "artist_external_id" => "mbid:artist:a1",
        "album" => "OK Computer", "album_external_id" => "mbid:rg:r1"
      }.to_json
    )
    Rewind::Play.create(user_id: @user.id, item_id: track.id,
                        played_at: Time.now + 1, source: "jellyfin")
    Rewind::UserItem.create(user_id: @user.id, item_key: @album.rating_key,
                            rating: 4)

    get "/history?type=track"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "cover-card--group"
    assert_includes last_response.body, %[action="/items/#{@album.id}/rating"]
    assert_includes last_response.body, "on-cover"
    assert_includes last_response.body,
                    'value="4" aria-label="4 stars" aria-pressed="true"'
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
