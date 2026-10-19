# frozen_string_literal: true

require "test_helper"

class SettingsSourcesTest < Minitest::Test
  def setup
    @user = create_user
    sign_in(@user)
  end

  def stub_auth(status: 200, access_token: "tok-1", user_id: "u-1",
                server_id: "srv-1")
    body = {
      "AccessToken" => access_token, "User" => {"Id" => user_id},
      "ServerId" => server_id
    }
    WebMock.stub_request(:post, "https://jf.test/Users/AuthenticateByName")
           .to_return(status:, body: body.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  test "connecting a Jellyfin account creates an encrypted source" do
    stub_auth(access_token: "secret-token", user_id: "jf-42",
              server_id: "srv-42")

    post "/settings/sources",
         {url: "https://jf.test", username: "fnando", password: "pw"}
    follow_redirect!

    source = @user.sources_dataset.first

    refute_nil source
    assert_equal "https://jf.test", source.url
    assert_equal "jf-42", source.external_user_id
    assert_equal "srv-42", source.instance_id
    assert_equal "secret-token", source.access_token
    refute_includes Rewind.db[:sources].first[:encrypted_credentials].to_s,
                    "secret-token"
  end

  test "re-adding the same account at a different URL is rejected" do
    stub_auth(user_id: "jf-1", server_id: "srv-1")
    post "/settings/sources",
         {url: "https://jf.test", username: "fnando", password: "pw"}
    follow_redirect!

    assert_equal 1, @user.sources_dataset.count

    # Same account on the same server, reached at a different URL (e.g. an
    # internal host). Keyed on instance_id now, so it's a duplicate.
    WebMock.stub_request(:post, "https://jf.internal/Users/AuthenticateByName")
           .to_return(
             status: 200,
             body: {
               "AccessToken" => "tok-2", "User" => {"Id" => "jf-1"},
               "ServerId" => "srv-1"
             }.to_json,
             headers: {"Content-Type" => "application/json"}
           )
    post "/settings/sources",
         {url: "https://jf.internal", username: "fnando", password: "pw"}

    assert_equal 1, @user.sources_dataset.count
    assert_includes last_response.body, "already connected"
  end

  test "a second Jellyfin account on the same server is its own source" do
    stub_auth(user_id: "jf-1", server_id: "srv-1")
    post "/settings/sources",
         {url: "https://jf.test", username: "a", password: "pw"}
    follow_redirect!

    stub_auth(user_id: "jf-2", server_id: "srv-1")
    post "/settings/sources",
         {url: "https://jf.test", username: "b", password: "pw"}
    follow_redirect!

    assert_equal 2, @user.sources_dataset.count
    assert_equal %w[jf-1 jf-2],
                 @user.sources_dataset.order(:external_user_id)
                      .select_map(:external_user_id)
  end

  test "bad credentials show an error and create no source" do
    stub_auth(status: 401)

    post "/settings/sources",
         {url: "https://jf.test", username: "x", password: "y"}

    assert_equal 0, @user.sources_dataset.count
  end

  test "a failed connection reopens the form prefilled with what was entered" do
    stub_auth(status: 401)

    post "/settings/sources",
         {url: "https://jf.test", username: "fnando", password: "y"}

    assert_equal 200, last_response.status
    # The disclosure is open and the URL/username are prefilled; the password
    # is never echoed back.
    assert_includes last_response.body, "<details class=\"disclosure\" open>"
    assert_includes last_response.body, %[value="https://jf.test"]
    assert_includes last_response.body, %[value="fnando"]
    refute_includes last_response.body, %[value="y"]
  end

  test "a failed connection is logged at info level (surfaced by --verbose)" do
    stub_auth(status: 401)

    io = StringIO.new
    original_level = Rewind.logger.level
    Rewind.logger.reopen(io)
    Rewind.logger.level = Logger::INFO

    begin
      post "/settings/sources",
           {url: "https://jf.test", username: "fnando", password: "y"}
    ensure
      Rewind.logger.level = original_level
      Rewind.logger.reopen($stdout)
    end

    assert_includes io.string, "[settings] jellyfin connection failed"
    assert_includes io.string, "fnando"
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
