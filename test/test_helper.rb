# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["REWIND_SESSION_SECRET"] ||= "a" * 128
ENV["TMDB_API_KEY"] ||= "test-tmdb-key"

require "base64"
require "json"
ENV["REWIND_KEYRING"] ||=
  JSON.generate({"1" => Base64.strict_encode64("a" * 32)})

require "simplecov"
SimpleCov.start do
  skip "/test/"
end

require "bundler/setup"
require "fileutils"
require "tmpdir"

TEST_DATA_DIR = Dir.mktmpdir("rewind-test-")
ENV["REWIND_DATA_DIR"] = TEST_DATA_DIR

require "webmock"
require "httpx"
require "httpx/adapters/webmock"
WebMock.enable!

require "rewind-app"
require "rewind/migrator"

Rewind.db = Sequel.sqlite
Rewind::Migrator.migrate!
Rewind.boot!
Rewind.application

require "minitest/utils"
require "minitest/autorun"
require "mocha/minitest"
require "rack/test"
require "webmock/minitest"

WebMock.disable_net_connect!(allow_localhost: true)

Dir["#{__dir__}/support/**/*.rb"].each do |file|
  require file
end

module Minitest
  class Test
    include Rack::Test::Methods

    alias _rewind_original_run run

    def run
      result = nil
      Rewind.db.transaction(rollback: :always, auto_savepoint: true) do
        result = _rewind_original_run
      end
      result
    end

    def app
      Rewind.application
    end

    def sign_in(user, password: "a-secure-password-123")
      post "/login", {username: user.username, password: password}
      follow_redirect! if last_response.redirect?
    end

    def create_user(attrs = {})
      user = Rewind::User.new(
        username: attrs[:username] || "user#{SecureRandom.hex(3)}",
        name: attrs[:name]
      )
      user.password = attrs[:password] || "a-secure-password-123"
      user.must_change_password = attrs.fetch(:must_change_password, false)
      user.save
      user
    end

    def create_source(attrs = {})
      token = attrs.delete(:access_token) || "token-#{SecureRandom.hex(4)}"
      source = Rewind::Source.new({
        user_id: attrs[:user_id],
        type: "jellyfin",
        url: "https://jf-#{SecureRandom.hex(3)}.test",
        external_user_id: "jf-#{SecureRandom.hex(3)}",
        instance_id: "srv-#{SecureRandom.hex(3)}"
      }.merge(attrs))
      source.credentials = {"access_token" => token}
      source.save
      source
    end

    def create_item(attrs = {})
      defaults = {
        media_type: "movie",
        external_id: "tmdb:#{SecureRandom.random_number(10_000_000)}",
        title: "Test Movie",
        runtime: 120,
        fetched_at: Time.now,
        metadata_json: {"genres" => [{"name" => "Drama"}]}.to_json
      }
      Rewind::Item.create(defaults.merge(attrs))
    end
  end
end
