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

  def create_source(url)
    user = Rewind::User.new(username: "u#{SecureRandom.hex(3)}")
    user.password = "a-secure-password-123"
    user.save
    source = Rewind::Source.new(user_id: user.id, type: "jellyfin", url:,
                                external_user_id: "jf-1")
    source.credentials = {"access_token" => "tok"}
    source.save
    source
  end

  test "sources:list prints connected sources" do
    create_source("https://room.example.com")
    out, = capture { Rewind::CLI.start(["sources:list"]) }

    assert_includes out, "room.example.com"
  end

  test "sources:disable disables a source" do
    source = create_source("https://off.example.com")
    capture do
      Rewind::CLI.start(["sources:disable", "--id", source.id.to_s])
    end

    refute source.refresh.enabled?
  end

  test "sources:enable re-enables a source" do
    source = create_source("https://on.example.com")
    source.update(enabled: false)
    capture { Rewind::CLI.start(["sources:enable", "--id", source.id.to_s]) }

    assert source.refresh.enabled?
  end

  test "sources:delete removes a source" do
    source = create_source("https://del.example.com")
    capture do
      Rewind::CLI.start(["sources:delete", "--id", source.id.to_s, "--yes"])
    end

    assert_nil Rewind::Source[source.id]
  end
end
