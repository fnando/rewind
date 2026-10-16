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

class WebhookModelTest < Minitest::Test
  def build_webhook(token: Rewind::Webhook.generate_token, **attrs)
    webhook = Rewind::Webhook.new(
      {type: "jellyfin", url: "https://jf.test"}.merge(attrs)
    )
    webhook.token = token
    webhook
  end

  test "generate_token produces unique strings" do
    tokens = Array.new(5) { Rewind::Webhook.generate_token }

    assert_equal tokens.uniq.size, tokens.size
  end

  test "rejects unknown type" do
    refute build_webhook(type: "zorg").valid?
  end

  test "normalizes the url by stripping trailing slashes" do
    assert_equal "https://jf.test", build_webhook(url: "https://jf.test/").url
  end

  test "stores the token hashed, never in plaintext" do
    token = Rewind::Webhook.generate_token
    webhook = build_webhook(token:)
    webhook.save

    reloaded = Rewind::Webhook[webhook.id]

    assert_equal Rewind::Webhook.digest_token(token), reloaded.token_digest
    refute_equal token, reloaded.token_digest
    assert_nil reloaded.token
  end

  test "rotate_token! returns a new plaintext token and changes the digest" do
    webhook = build_webhook
    webhook.save
    before = webhook.token_digest

    new_token = webhook.rotate_token!

    assert_equal new_token, webhook.plain_token
    refute_equal before, webhook.token_digest
    assert_equal Rewind::Webhook.digest_token(new_token), webhook.token_digest
  end
end

class IntegrationModelTest < Minitest::Test
  def create_webhook
    webhook = Rewind::Webhook.new(
      type: "jellyfin", url: "https://jf-#{SecureRandom.hex(3)}.test"
    )
    webhook.token = Rewind::Webhook.generate_token
    webhook.save
    webhook
  end

  test "requires a webhook" do
    integration = Rewind::Integration.new(
      user_id: create_user.id, external_user_id: "u"
    )

    refute integration.valid?
    assert_includes integration.errors[:webhook_id], "is required"
  end

  test "requires an external_user_id" do
    integration = Rewind::Integration.new(
      user_id: create_user.id, webhook_id: create_webhook.id
    )

    refute integration.valid?
    assert_includes integration.errors[:external_user_id], "is required"
  end

  test "is valid with user, webhook and external_user_id" do
    integration = Rewind::Integration.new(
      user_id: create_user.id, webhook_id: create_webhook.id,
      external_user_id: "jf-1"
    )

    assert integration.valid?
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
    %w[track album artist].each do |type|
      assert_includes Rewind::Item::MEDIA_TYPES, type
    end
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

class UserItemModelTest < Minitest::Test
  test "rating must be 1..5" do
    user = create_user
    item = create_item
    ui = Rewind::UserItem.new(user_id: user.id, item_id: item.id, rating: 7)

    refute ui.valid?
  end

  test "nil rating is valid" do
    user = create_user
    item = create_item
    ui = Rewind::UserItem.new(user_id: user.id, item_id: item.id, review: "ok")

    assert ui.valid?
  end
end
