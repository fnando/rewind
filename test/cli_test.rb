# frozen_string_literal: true

require "test_helper"
require "stringio"

class CLITest < Minitest::Test
  def capture
    out, err = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = out, err
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
end
