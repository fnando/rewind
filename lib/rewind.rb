# frozen_string_literal: true

require "thor"
require "sequel"
require "sqlite3"
require "attr_keyring"
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

  LEAD_CHARACTERS = JSON.parse(File.read(File.expand_path(
                                           "rewind/data/lead_characters.json",
                                           __dir__
                                         ))).freeze

  class Error < StandardError; end

  class << self
    def config
      @config ||= Config.new
    end

    attr_writer :config, :db, :logger

    def db
      @db ||= begin
        FileUtils.mkdir_p(config.data_dir)
        # WAL lets web reads run concurrently with the background sync thread's
        # writes. In the default rollback-journal mode they deadlock on the
        # single writer lock (busy_timeout can't break it), surfacing as
        # "database is locked". WAL is persistent, so it applies to every
        # pooled connection; synchronous: normal is the safe WAL pairing.
        database = Sequel.sqlite(config.db_path.to_s, synchronous: :normal)
        database.run("PRAGMA journal_mode = WAL")
        database
      end
    end

    def logger
      @logger ||= Logger.new($stdout, level: Logger::WARN)
    end

    def root
      @root ||= File.expand_path("..", __dir__)
    end

    def boot!
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
