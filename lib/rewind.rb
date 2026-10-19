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
        # writes. SQLite still allows only one writer at a time, so when the web
        # app and a separate `sync` process write at once, the loser
        # must wait: busy_timeout (per connection, via Sequel's :timeout, ms)
        # makes it retry instead of raising "database is locked". WAL is
        # persistent; synchronous: normal is the safe WAL pairing.
        database = Sequel.sqlite(
          config.db_path.to_s,
          synchronous: :normal,
          timeout: config.db_busy_timeout
        )
        database.run("PRAGMA journal_mode = WAL")
        # Take the write lock up front (BEGIN IMMEDIATE) on every write
        # transaction. A default deferred transaction that reads then writes can
        # get an un-retryable "database is locked" the instant another writer
        # holds the lock; grabbing it first means busy_timeout governs the wait.
        database.transaction_mode = :immediate
        database
      end
    end

    def logger
      @logger ||= Logger.new(
        $stdout,
        level: Logger::WARN,
        formatter: proc do |severity, time, _progname, message|
          "[rewind] #{time.strftime('%Y-%m-%dT%H:%M:%S')} #{severity} " \
            "#{message}\n"
        end
      )
    end

    def root
      @root ||= File.expand_path("..", __dir__)
    end

    def boot!
      db
      require_relative "rewind/boot"
    end

    def application
      boot!
      require_relative "rewind/application"
      Application
    end
  end
end

require_relative "rewind/cli"
