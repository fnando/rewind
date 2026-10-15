# frozen_string_literal: true

require "test_helper"

class AuthTest < Minitest::Test
  test "login page renders" do
    get "/login"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Sign in"
  end

  test "login page shows hint when there are no users" do
    assert_equal 0, Rewind::User.count
    get "/login"

    assert_includes last_response.body, "rewind users:new"
  end

  test "unauthenticated requests redirect to login" do
    get "/"

    assert_equal 302, last_response.status
    assert_includes last_response.headers["location"], "/login"
  end

  test "logging in with valid credentials sets session" do
    user = create_user(username: "me", password: "a-secure-password-123")
    post "/login", {username: "me", password: "a-secure-password-123"}

    assert_equal 302, last_response.status
    follow_redirect!
    follow_redirect! if last_response.redirect?

    assert_equal 200, last_response.status
    refute_nil user.reload.last_login_at
  end

  test "logging in with invalid credentials fails" do
    create_user(username: "me", password: "a-secure-password-123")
    post "/login", {username: "me", password: "wrong"}

    assert_equal 401, last_response.status
    assert_includes last_response.body, "Invalid username"
  end

  test "logout clears session" do
    user = create_user
    sign_in(user)
    post "/logout"

    assert_equal 302, last_response.status
    get "/"

    assert_equal 302, last_response.status
    assert_includes last_response.headers["location"], "/login"
  end

  test "must_change_password forces password screen" do
    user = create_user(must_change_password: true)
    sign_in(user)
    get "/"

    assert_equal 302, last_response.status
    assert_includes last_response.headers["location"], "/settings/password"
  end
end
