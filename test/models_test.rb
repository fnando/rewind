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

class IntegrationModelTest < Minitest::Test
  test "generate_token produces unique strings" do
    tokens = Array.new(5) { Rewind::Integration.generate_token }
    assert_equal tokens.uniq.size, tokens.size
  end

  test "rejects unknown kind" do
    user = create_user
    integration = Rewind::Integration.new(
      user_id: user.id,
      kind: "zorg",
      label: "x",
      external_user_id: "u",
      token: "t"
    )
    refute integration.valid?
  end

  test "requires external_user_id for jellyfin" do
    user = create_user
    integration = Rewind::Integration.new(
      user_id: user.id, kind: "jellyfin", label: "L", token: "t"
    )
    refute integration.valid?
    assert_includes integration.errors[:external_user_id], "is required for Jellyfin integrations"
  end
end

class PlayModelTest < Minitest::Test
  test "invalid source is rejected" do
    user = create_user
    item = create_item
    play = Rewind::Play.new(user_id: user.id, item_id: item.id, played_at: Time.now, source: "bogus")
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
