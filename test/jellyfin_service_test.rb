# frozen_string_literal: true

require "test_helper"

class JellyfinServiceTest < Minitest::Test
  def stub_public_users(url, users)
    WebMock.stub_request(:get, "#{url}/Users/Public")
           .to_return(status: 200, body: users.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  test "returns id/name pairs from /Users/Public" do
    stub_public_users(
      "https://jf.test",
      [
        {"Id" => "abc", "Name" => "fnando"},
        {"Id" => "def", "Name" => "guga"}
      ]
    )

    users = Rewind::Services::Jellyfin.public_users("https://jf.test/")

    assert_equal(
      [{id: "abc", name: "fnando"}, {id: "def", name: "guga"}],
      users
    )
  end

  test "returns an empty list when the server is unreachable" do
    WebMock.stub_request(:get, "https://down.test/Users/Public").to_timeout

    assert_empty Rewind::Services::Jellyfin.public_users("https://down.test")
  end

  test "returns an empty list for a non-success response" do
    WebMock.stub_request(:get, "https://jf.test/Users/Public")
           .to_return(status: 404)

    assert_empty Rewind::Services::Jellyfin.public_users("https://jf.test")
  end
end
