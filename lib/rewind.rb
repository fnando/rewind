# frozen_string_literal: true

require "thor"
require "sequel"
require "sqlite3"
require "bcrypt"
require "json"
require "securerandom"
require "openssl"
require "fileutils"
require "logger"
require "digest/md5"
require "tzinfo"

Sequel.default_timezone = :utc
Sequel.application_timezone = :utc

module Rewind
  require_relative "rewind/version"
  require_relative "rewind/config"

  LEAD_CHARACTERS = JSON.parse(File.read(File.expand_path("rewind/data/lead_characters.json", __dir__))).freeze

  class Error < StandardError; end

  class << self
    def config
      @config ||= Config.new
    end

    attr_writer :config, :db, :logger

    def db
      @db ||= begin
        FileUtils.mkdir_p(config.data_dir)
        Sequel.sqlite(config.db_path.to_s)
      end
    end

    def logger
      @logger ||= Logger.new($stdout)
    end

    def root
      @root ||= File.expand_path("..", __dir__)
    end

    def boot!
      config.require_salt!
      db
      require_relative "rewind/models"
    end

    def application
      boot!
      require_relative "rewind/application"
      Application
    end
  end
end

require_relative "rewind/cli"
