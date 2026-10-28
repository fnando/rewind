# frozen_string_literal: true

require "test_helper"

class PlayCardTest < Minitest::Test
  def setup
    @user = create_user
    @series = create_item(
      media_type: "series", external_id: "tmdb:1399", title: "GoT",
      metadata_json: {
        "series_name" => "GoT",
        "seasons" => [
          {"season_number" => 1, "poster_path" => "/s1.jpg"},
          {"season_number" => 2} # no poster
        ]
      }.to_json
    )
  end

  def card_for(episode)
    play = Rewind::Play.create(user_id: @user.id, item_id: episode.id,
                               played_at: Time.now, source: "manual")
    Rewind::Presenters::PlayCard.new(
      play, shows: {@series.external_id => @series}
    )
  end

  def episode(season:)
    create_item(media_type: "episode", external_id: "tmdb:ep#{season}",
                parent_external_id: @series.external_id, title: "Ep",
                season_number: season, episode_number: 1)
  end

  test "cover_item uses the season poster when the series carries one" do
    cover = card_for(episode(season: 1)).cover_item

    assert_instance_of Rewind::Presenters::PlayCard::SeasonCover, cover
    assert_equal "season", cover.media_type
    assert_equal "tmdb:1399:1", cover.external_id
  end

  test "cover_item falls back to the show when the season has no poster" do
    assert_equal @series, card_for(episode(season: 2)).cover_item
  end

  test "cover_item falls back to the show for an unknown season" do
    assert_equal @series, card_for(episode(season: 9)).cover_item
  end

  test "cover_item falls back to the episode when the show is not loaded" do
    ep = episode(season: 1)
    play = Rewind::Play.create(user_id: @user.id, item_id: ep.id,
                               played_at: Time.now, source: "manual")
    card = Rewind::Presenters::PlayCard.new(play, shows: {})

    assert_equal play.item, card.cover_item
  end

  test "cover_item is the item itself for non-episodes" do
    movie = create_item(media_type: "movie", external_id: "tmdb:603",
                        title: "The Matrix")
    play = Rewind::Play.create(user_id: @user.id, item_id: movie.id,
                               played_at: Time.now, source: "manual")
    card = Rewind::Presenters::PlayCard.new(play)

    assert_equal movie, card.cover_item
  end

  test "a music video card is labelled and links to its artist" do
    artist = create_item(media_type: "artist", external_id: "mbid:artist:a1",
                         title: "Green Day")
    video = create_item(
      media_type: "music_video", external_id: "youtube:v1",
      title: "Basket Case",
      metadata_json: {
        "artist" => "Green Day",
        "artist_external_id" => "mbid:artist:a1"
      }.to_json
    )
    play = Rewind::Play.create(user_id: @user.id, item_id: video.id,
                               played_at: Time.now, source: "jellyfin")
    card = Rewind::Presenters::PlayCard.new(
      play, music_parents: {artist.external_id => artist}
    )

    assert_equal "music_video", card.kind
    assert_equal "Music Video", card.kind_label
    assert_equal artist, card.artist_item
  end
end
