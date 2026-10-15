# frozen_string_literal: true

require "test_helper"
require "stringio"

class CLITest < Minitest::Test
  def capture
    out = $stdout
    err = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = out
    $stderr = err
  end

  test "users:new creates a user with a generated password" do
    out, = capture { Rewind::CLI.start(["users:new", "--username", "alice"]) }

    assert_includes out, "User created"
    assert_includes out, "alice"
    user = Rewind::User.where(username: "alice").first

    assert user
    assert user.must_change_password
  end

  test "users:update --new-password resets the password" do
    user = create_user(username: "bob")
    user.update(must_change_password: false)
    out, = capture { Rewind::CLI.start(["users:update", "--username", "bob", "--new-password"]) }

    assert_includes out, "User updated"
    user.reload

    assert user.must_change_password
  end

  test "users:delete removes the user" do
    create_user(username: "cathy")
    capture { Rewind::CLI.start(["users:delete", "--username", "cathy", "--yes"]) }

    assert_nil Rewind::User.where(username: "cathy").first
  end

  test "users:list prints users" do
    create_user(username: "dan")
    out, = capture { Rewind::CLI.start(["users:list"]) }

    assert_includes out, "dan"
  end

  def allowlist(url)
    webhook = Rewind::Webhook.new(type: "jellyfin", url:)
    webhook.token = Rewind::Webhook.generate_token
    webhook.save
    webhook
  end

  test "webhooks:new allowlists an instance and prints the webhook url" do
    out, = capture do
      Rewind::CLI.start(["webhooks:new", "--url", "https://jf.example.com/"])
    end

    assert_includes out, "Instance allowlisted"
    assert_includes out, "/webhooks/jellyfin/"
    webhook = Rewind::Webhook.where(url: "https://jf.example.com").first

    assert webhook
    assert webhook.enabled?
  end

  test "webhooks:list prints allowlisted instances" do
    allowlist("https://room.example.com")
    out, = capture { Rewind::CLI.start(["webhooks:list"]) }

    assert_includes out, "room.example.com"
  end

  test "webhooks:update --no-enabled disables an instance" do
    webhook = allowlist("https://off.example.com")
    capture do
      Rewind::CLI.start(
        ["webhooks:update", "--url", "https://off.example.com", "--no-enabled"]
      )
    end

    refute webhook.reload.enabled?
  end

  test "webhooks:rotate changes the token" do
    webhook = allowlist("https://rot.example.com")
    before = webhook.token_digest
    capture do
      Rewind::CLI.start(["webhooks:rotate", "--url", "https://rot.example.com"])
    end

    refute_equal before, webhook.reload.token_digest
  end

  test "webhooks:delete removes an instance" do
    allowlist("https://del.example.com")
    capture do
      Rewind::CLI.start(
        ["webhooks:delete", "--url", "https://del.example.com", "--yes"]
      )
    end

    assert_nil Rewind::Webhook.where(url: "https://del.example.com").first
  end
end
