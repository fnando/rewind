# frozen_string_literal: true

require "test_helper"

class ErrorLogModelTest < Minitest::Test
  test "record stores class, message, backtrace and context" do
    error =
      begin
        raise "boom"
      rescue RuntimeError => error
        error
      end

    log = Rewind::ErrorLog.record(error, context: {"path" => "/x"})

    assert_equal "RuntimeError", log.error_class
    assert_equal "boom", log.message
    assert_includes log.backtrace, "errors_test.rb"
    assert_equal "/x", log.context["path"]
  end

  test "record never raises, returning nil when it can't persist" do
    Rewind::ErrorLog.stubs(:create).raises(Sequel::DatabaseError.new("x"))

    assert_nil Rewind::ErrorLog.record(RuntimeError.new("boom"))
  end

  test "context is an empty hash when none was stored" do
    log = Rewind::ErrorLog.record(RuntimeError.new("boom"))

    assert_empty log.context
    assert_nil log.context_json
  end
end

class ErrorsPageTest < Minitest::Test
  def setup
    @admin = create_user
    @admin.update(admin: true)
    @user = create_user
  end

  def seed_error(message: "boom", klass: "RuntimeError")
    Rewind::ErrorLog.create(
      error_class: klass, message: message,
      backtrace: "lib/foo.rb:1:in `bar'",
      context_json: {"path" => "/stats"}.to_json
    )
  end

  test "an admin sees the error list" do
    seed_error(message: "something failed")
    sign_in(@admin)

    get "/settings/errors"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "something failed"
  end

  test "an admin sees an error's full detail" do
    error = seed_error(message: "detail boom")
    sign_in(@admin)

    get "/settings/errors/#{error.id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "detail boom"
    assert_includes last_response.body, "lib/foo.rb:1"
    assert_includes last_response.body, "/stats" # the context data
  end

  test "a non-admin cannot see the error pages" do
    error = seed_error
    sign_in(@user)

    get "/settings/errors"

    assert_equal 404, last_response.status

    get "/settings/errors/#{error.id}"

    assert_equal 404, last_response.status
  end

  test "the settings page links the error log only for admins" do
    sign_in(@admin)
    get "/settings"

    assert_includes last_response.body, "/settings/errors"

    sign_in(@user)
    get "/settings"

    refute_includes last_response.body, "/settings/errors"
  end

  test "an unhandled request error is captured with its context" do
    Rewind::Services::Stats.stubs(:new).raises(RuntimeError.new("kaboom"))
    sign_in(@user)

    get "/stats"

    assert_equal 500, last_response.status
    log = Rewind::ErrorLog.order(:id).last

    refute_nil log
    assert_equal "kaboom", log.message
    assert_equal "/stats", log.context["path"]
    assert_equal @user.id, log.context["user_id"]
  end

  test "the list paginates" do
    (Rewind::Application::ERRORS_PER_PAGE + 1).times {|i| seed_error(message: "e#{i}") }
    sign_in(@admin)

    get "/settings/errors"

    assert_includes last_response.body, ">Older</a>"

    get "/settings/errors?page=2"

    assert_includes last_response.body, ">Newer</a>"
  end
end
