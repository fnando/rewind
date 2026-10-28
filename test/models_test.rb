# frozen_string_literal: true

require "test_helper"

class UserModelTest < Minitest::Test
  test "requires a username" do
    user = Rewind::User.new
    user.password = "foo"

    refute user.valid?
    assert_includes user.errors.on(:username), "is required"
  end

  test "username must be url-safe" do
    user = Rewind::User.new(username: "has spaces")
    user.password = "foo"

    refute user.valid?
  end

  test "authenticate returns true for correct password" do
    user = create_user(password: "the-correct-horse")

    assert user.authenticate("the-correct-horse")
    refute user.authenticate("wrong")
  end

  test "default rating_style is stars" do
    user = create_user

    assert_equal "stars", user.rating_style
  end
end

class SourceModelTest < Minitest::Test
  def build_source(**attrs)
    source = Rewind::Source.new({
      user_id: create_user.id, type: "jellyfin", url: "https://jf.test",
      external_user_id: "jf-1", instance_id: "srv-1"
    }.merge(attrs))
    source.credentials = {"access_token" => "secret-token"}
    source
  end

  test "rejects unknown type" do
    refute build_source(type: "zorg").valid?
  end

  test "requires url, external_user_id, instance_id and credentials" do
    source = Rewind::Source.new(user_id: create_user.id, type: "jellyfin")

    refute source.valid?
    assert_includes source.errors[:url], "is required"
    assert_includes source.errors[:external_user_id], "is required"
    assert_includes source.errors[:instance_id], "is required"
    assert_includes source.errors[:credentials], "is required"
  end

  test "the same server and account is allowed under different users" do
    attrs = {
      url: "https://jf.test", external_user_id: "jf-1",
      instance_id: "srv-1"
    }
    build_source(**attrs).save

    other = build_source(user_id: create_user.id, **attrs)

    assert other.valid?
    other.save # scoped per user, so no unique-index clash

    assert_equal 2, Rewind::Source.where(instance_id: "srv-1").count
  end

  test "normalizes the url by stripping trailing slashes" do
    assert_equal "https://jf.test", build_source(url: "https://jf.test/").url
  end

  test "is valid with user, url, external_user_id and credentials" do
    assert build_source.valid?
  end

  test "stores credentials encrypted, decrypting on read" do
    source = build_source
    source.save

    row = Rewind.db[:sources].where(id: source.id).first

    refute_includes row[:encrypted_credentials].to_s, "secret-token"
    refute_nil row[:keyring_id]
    assert_equal "secret-token", Rewind::Source[source.id].access_token
  end
end

class ItemModelTest < Minitest::Test
  test "tmdb_id and parent_tmdb_id are derived from external_id" do
    item = create_item(media_type: "episode", external_id: "tmdb:42",
                       parent_external_id: "tmdb:7")

    assert_equal 42, item.tmdb_id
    assert_equal 7, item.parent_tmdb_id
  end

  test "mbid is derived only for mbid external_id" do
    track = create_item(media_type: "track", external_id: "mbid:abc-123",
                        title: "Song")

    assert_equal "abc-123", track.mbid
    assert_nil create_item(external_id: "tmdb:99").mbid
  end

  test "track display_title joins artist and title" do
    track = create_item(
      media_type: "track", external_id: "mbid:abc", title: "Song",
      metadata_json: {"artist" => "Artist"}.to_json
    )

    assert_equal "Artist — Song", track.display_title
  end

  test "track and album and artist are valid media types" do
    %w[track album artist music_video].each do |type|
      assert_includes Rewind::Item::MEDIA_TYPES, type
    end
  end

  test "music_video display_title joins artist and title" do
    video = create_item(
      media_type: "music_video", external_id: "youtube:v1", title: "Creep",
      metadata_json: {"artist" => "Radiohead"}.to_json
    )

    assert_equal "Radiohead — Creep", video.display_title
  end
end

class PlayModelTest < Minitest::Test
  test "invalid source is rejected" do
    user = create_user
    item = create_item
    play = Rewind::Play.new(user_id: user.id, item_id: item.id,
                            played_at: Time.now, source: "bogus")

    refute play.valid?
  end
end

class ItemRatingKeyTest < Minitest::Test
  test "rating_key uses the jellyfin id when present" do
    item = create_item(media_type: "movie", external_id: "tmdb:9",
                       jellyfin_id: "jf-1")

    assert_equal "jellyfin:jf-1", item.rating_key
  end

  test "rating_key falls back to media_type and external_id" do
    item = create_item(media_type: "movie", external_id: "tmdb:9")

    assert_equal "movie:tmdb:9", item.rating_key
  end

  test "a re-tag (new external_id, same jellyfin id) keeps the same key" do
    a = create_item(media_type: "album", external_id: "mbid:rg:OLD",
                    jellyfin_id: "jf-album")
    b = create_item(media_type: "album", external_id: "mbid:rg:NEW",
                    jellyfin_id: "jf-album")

    assert_equal a.rating_key, b.rating_key
  end
end

class UserItemModelTest < Minitest::Test
  test "rating must be 1..5" do
    user = create_user
    ui = Rewind::UserItem.new(user_id: user.id, item_key: "movie:tmdb:1",
                              rating: 7)

    refute ui.valid?
  end

  test "nil rating is valid" do
    user = create_user
    ui = Rewind::UserItem.new(user_id: user.id, item_key: "movie:tmdb:1",
                              review: "ok")

    assert ui.valid?
  end
end
