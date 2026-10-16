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

  def item(id, last_played, name: "Movie")
    {
      "Id" => id, "ItemType" => "Movie", "Name" => name,
      "UserData" => {"LastPlayedDate" => last_played, "Played" => true}
    }
  end

  def stub_items(body, start_index: 0)
    WebMock.stub_request(:get, %r{https://jf\.test/Users/u-1/Items})
           .with(query: hash_including("StartIndex" => start_index.to_s))
           .to_return(status: 200, body: body.to_json,
                      headers: {"Content-Type" => "application/json"})
  end

  test "authenticate returns the access token and jellyfin user id" do
    WebMock.stub_request(:post, "https://jf.test/Users/AuthenticateByName")
           .with(body: {Username: "fnando", Pw: "secret"}.to_json)
           .to_return(
             status: 200,
             body: {
               "AccessToken" => "tok-123",
               "User" => {"Id" => "u-1"}
             }.to_json,
             headers: {"Content-Type" => "application/json"}
           )

    result = Rewind::Services::Jellyfin.new("https://jf.test/")
                                       .authenticate(username: "fnando",
                                                     password: "secret")

    assert_equal({access_token: "tok-123", user_id: "u-1"}, result)
  end

  test "authenticate raises AuthError on invalid credentials" do
    WebMock.stub_request(:post, "https://jf.test/Users/AuthenticateByName")
           .to_return(status: 401)

    assert_raises(Rewind::Services::Jellyfin::AuthError) do
      Rewind::Services::Jellyfin.new("https://jf.test")
                                .authenticate(username: "x", password: "y")
    end
  end

  test "played_items returns only items newer than the cursor" do
    stub_items({
                 "Items" => [
                   item("a", "2026-10-16T05:00:00Z"),
                   item("b", "2026-10-16T04:00:00Z"),
                   item("c", "2026-10-16T03:00:00Z")
                 ], "TotalRecordCount" => 3
               })

    client = Rewind::Services::Jellyfin.new("https://jf.test", token: "t")
    items = client.played_items(user_id: "u-1", since: "2026-10-16T04:00:00Z")

    assert_equal(%w[a], items.map {|i| i["Id"] })
  end

  test "played_items paginates until the records are exhausted" do
    stub_items({
                 "Items" => Array.new(2) do |n|
                   item("p#{n}",
                        "2026-10-16T0#{9 - n}:00:00Z")
                 end,
                 "TotalRecordCount" => 4
               }, start_index: 0)
    stub_items({
                 "Items" => Array.new(2) do |n|
                   item("q#{n}",
                        "2026-10-16T0#{3 - n}:00:00Z")
                 end,
                 "TotalRecordCount" => 4
               }, start_index: 2)

    items = Rewind::Services::Jellyfin.new("https://jf.test", token: "t",
                                                              page_size: 2)
                                      .played_items(user_id: "u-1")

    assert_equal(%w[p0 p1 q0 q1], items.map {|i| i["Id"] })
  end
end
