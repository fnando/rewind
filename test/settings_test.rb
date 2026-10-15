# frozen_string_literal: true

require "test_helper"

class SettingsJellyfinUsersTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)
    @webhook = Rewind::Webhook.new(type: "jellyfin", url: "https://jf.test")
    @webhook.token = Rewind::Webhook.generate_token
    @webhook.save
  end

  test "returns 404 for an unknown instance" do
    get "/settings/jellyfin-users?webhook_id=999999"

    assert_equal 404, last_response.status
  end

  test "returns the instance's public users as JSON" do
    WebMock.stub_request(:get, "https://jf.test/Users/Public")
           .to_return(
             status: 200,
             body: [{"Id" => "abc", "Name" => "fnando"}].to_json,
             headers: {"Content-Type" => "application/json"}
           )

    get "/settings/jellyfin-users?webhook_id=#{@webhook.id}"

    assert_equal 200, last_response.status
    assert_equal [{"id" => "abc", "name" => "fnando"}],
                 JSON.parse(last_response.body)
  end

  test "requires login" do
    clear_cookies
    get "/settings/jellyfin-users?webhook_id=#{@webhook.id}"

    assert_equal 302, last_response.status
    assert_includes last_response.headers["location"], "/login"
  end
end
