# frozen_string_literal: true

require "test_helper"

class InfoTest < Minitest::Test
  test "GET /info returns version, environment and tz data without auth" do
    get "/info" # no sign-in

    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type.split(";").first

    body = JSON.parse(last_response.body)

    assert_equal Rewind::VERSION, body["version"]
    assert_equal "test", body["environment"]
    assert_match(/\A\d+\.\d+\.\d+\z/, body["tzdata_version"])
  end
end
