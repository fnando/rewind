# frozen_string_literal: true

require "test_helper"

class SettingsSourcesTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)
  end

  def stub_auth(status: 200, access_token: "tok-1", user_id: "u-1")
    body = {"AccessToken" => access_token, "User" => {"Id" => user_id}}
    WebMock.stub_request(:post, "https://jf.test/Users/AuthenticateByName")
           .to_return(status:, body: body.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  test "connecting a Jellyfin account creates an encrypted source" do
    stub_auth(access_token: "secret-token", user_id: "jf-42")

    post "/settings/sources",
         {url: "https://jf.test", username: "fnando", password: "pw"}
    follow_redirect!

    source = @user.sources_dataset.first

    refute_nil source
    assert_equal "https://jf.test", source.url
    assert_equal "jf-42", source.external_user_id
    assert_equal "secret-token", source.access_token
    refute_includes Rewind.db[:sources].first[:encrypted_credentials].to_s,
                    "secret-token"
  end

  test "bad credentials show an error and create no source" do
    stub_auth(status: 401)

    post "/settings/sources",
         {url: "https://jf.test", username: "x", password: "y"}

    assert_equal 0, @user.sources_dataset.count
  end

  test "toggling a source flips enabled" do
    source = create_source(user_id: @user.id)

    post "/settings/sources/#{source.id}/toggle"

    refute source.refresh.enabled?
  end

  test "deleting a source removes it" do
    source = create_source(user_id: @user.id)

    delete "/settings/sources/#{source.id}"

    assert_nil Rewind::Source[source.id]
  end

  test "a user cannot toggle another user's source" do
    other = create_source(user_id: create_user.id)

    post "/settings/sources/#{other.id}/toggle"

    assert_equal 404, last_response.status
  end
end
