# frozen_string_literal: true

require "thor"
require "dotenv"

module Rewind
  class UsersCLI < Thor
    class_option :env, type: :string,
                       desc: "Path to a dotenv file to load before executing"

    def self.exit_on_failure?
      true
    end

    desc "new", "Create a new user with a generated password"
    option :username, type: :string, required: true
    option :name, type: :string
    def new
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!
      password = Rewind::Services::PasswordGenerator.call
      user = Rewind::User.new(
        username: options[:username],
        name: options[:name]
      )
      user.password = password
      user.must_change_password = true

      if user.valid?
        user.save
        say_header("User created")
        say_kv("username", user.username)
        say_kv("password", password)
        say "\nShare the password with the user. They will be forced " \
            "to change it on first login."
      else
        say "Could not create user:"
        user.errors.each {|field, errs| say "  #{field}: #{errs.join(', ')}" }
        exit 1
      end
    end

    desc "update", "Update a user"
    option :username, type: :string, required: true
    option :new_password, type: :boolean, default: false,
                          desc: "Regenerate the password"
    option :name, type: :string
    option :rating_style, type: :string, enum: %w[stars thumbs]
    def update
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!
      user = Rewind::User.where(username: options[:username]).first
      abort("User not found: #{options[:username]}") unless user

      user.set(name: options[:name]) if options.key?(:name)
      user.set(rating_style: options[:rating_style]) if options[:rating_style]

      password = nil
      if options[:new_password]
        password = Rewind::Services::PasswordGenerator.call
        user.password = password
        user.must_change_password = true
      end

      user.save
      say_header("User updated")
      say_kv("username", user.username)
      say_kv("password", password) if password
    end

    desc "delete", "Delete a user and their data"
    option :username, type: :string, required: true
    option :yes, type: :boolean, default: false
    def delete
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!
      user = Rewind::User.where(username: options[:username]).first
      abort("User not found: #{options[:username]}") unless user

      unless options[:yes]
        print "Delete #{user.username} and all their data? [y/N] "
        answer = $stdin.gets.to_s.strip.downcase
        abort("Aborted.") unless %w[y yes].include?(answer)
      end

      user.destroy
      say "Deleted #{options[:username]}."
    end

    desc "list", "List users"
    def list
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!
      rows = Rewind::User.order(:username).all
      if rows.empty?
        say "No users yet. Run: rewind users:new --username USERNAME"
        return
      end

      say "USERNAME             NAME                 " \
          "CREATED              LAST LOGIN          "
      rows.each do |u|
        say format(
          "%-20s %-20s %-20s %-20s",
          u.username,
          u.name || "-",
          u.created_at&.strftime("%Y-%m-%d %H:%M") || "-",
          u.last_login_at&.strftime("%Y-%m-%d %H:%M") || "-"
        ).rstrip
      end
    end

    no_commands do
      def say_header(text)
        say "\n== #{text} =="
      end

      def say_kv(k, v)
        say format("  %-10s %s", "#{k}:", v)
      end
    end
  end

  class SourcesCLI < Thor
    class_option :env, type: :string,
                       desc: "Path to a dotenv file to load before executing"

    def self.exit_on_failure?
      true
    end

    LIST_FORMAT = "%-5s %-10s %-40s %-8s %-18s"

    desc "list", "List connected sync sources"
    def list
      boot!
      rows = Rewind::Source.order(:user_id, :type, :url).all
      if rows.empty?
        say "No sources connected. Users connect Jellyfin from Settings."
        return
      end

      say format(LIST_FORMAT, "ID", "TYPE", "URL", "ENABLED", "LAST SYNC")
      rows.each do |source|
        say format(
          LIST_FORMAT,
          source.id,
          source.type,
          source.url,
          source.enabled? ? "yes" : "no",
          source.last_synced_at&.strftime("%Y-%m-%d %H:%M") || "-"
        )
      end
    end

    desc "enable", "Enable a source by id"
    option :id, type: :numeric, required: true
    def enable
      boot!
      set_enabled(options[:id], true)
    end

    desc "disable", "Disable a source by id"
    option :id, type: :numeric, required: true
    def disable
      boot!
      set_enabled(options[:id], false)
    end

    desc "delete", "Delete a source by id"
    option :id, type: :numeric, required: true
    option :yes, type: :boolean, default: false
    def delete
      boot!
      source = find_source(options[:id])
      unless options[:yes]
        print "Delete source #{source.id} (#{source.url})? [y/N] "
        answer = $stdin.gets.to_s.strip.downcase
        abort("Aborted.") unless %w[y yes].include?(answer)
      end

      source.destroy
      say "Deleted source #{source.id}."
    end

    no_commands do
      def boot!
        Rewind::CLI.load_env!(options[:env])
        Rewind::CLI.boot_db!
      end

      def find_source(id)
        source = Rewind::Source[id.to_i]
        abort("Source not found: #{id}") unless source
        source
      end

      def set_enabled(id, value)
        source = find_source(id)
        source.update(enabled: value)
        say "Source #{source.id} #{value ? 'enabled' : 'disabled'}."
      end
    end
  end

  class ImportCLI < Thor
    class_option :env, type: :string,
                       desc: "Path to a dotenv file to load before executing"

    def self.exit_on_failure?
      true
    end

    desc "trakt", "Import watchings, ratings, and reviews from a Trakt export"
    option :archive, type: :string, required: true,
                     desc: "Path to the Trakt data export .zip"
    option :username, type: :string, required: true,
                      desc: "User the imported data belongs to"
    def trakt
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!

      archive = options[:archive]
      abort("Archive not found: #{archive}") unless File.file?(archive)
      user = Rewind::User.where(username: options[:username]).first
      abort("User not found: #{options[:username]}") unless user

      stats = Rewind::Services::Importers::Trakt.new(
        user:, archive:, out: $stdout
      ).call

      say_header("Import complete")
      say_kv("plays created", stats[:plays_created])
      say_kv("plays skipped", stats[:plays_skipped])
      say_kv("ratings set", stats[:ratings_set])
      say_kv("reviews set", stats[:reviews_set])
      say_kv("entries skipped", stats[:skipped])
    end

    no_commands do
      def say_header(text)
        say "\n== #{text} =="
      end

      def say_kv(k, v)
        say format("  %-18s %s", "#{k}:", v)
      end
    end
  end

  class CLI < Thor
    check_unknown_options!

    def self.exit_on_failure?
      true
    end

    def self.load_env!(path)
      return unless path

      abort("env file not found: #{path}") unless File.exist?(path)
      Dotenv.load(path)
      Rewind.config = Config.new
    end

    def self.boot_db!
      require_relative "migrator"
      Rewind::Migrator.migrate! if ENV["REWIND_AUTO_MIGRATE"] == "1"
      Rewind.boot!
    end

    class_option :env, type: :string,
                       desc: "Path to a dotenv file to load before executing"

    desc "run", "Start the Rewind web server"
    option :port, type: :numeric
    option :host, type: :string
    option :migrate, type: :boolean, default: false,
                     desc: "Run pending migrations before booting"
    option :verbose, type: :boolean, default: false, aliases: "-v",
                     desc: "Log sync activity at info level"
    option :image_storage_dir, type: :string,
                               desc: "Directory to cache proxied cover images"
    def run_server
      CLI.load_env!(options[:env])
      Rewind.logger.level = Logger::INFO if options[:verbose]
      require_relative "migrator"
      if options[:migrate] || ENV["REWIND_AUTO_MIGRATE"] == "1"
        Rewind::Migrator.migrate!
      elsif Rewind::Migrator.pending?
        abort "Pending migrations detected. " \
              "Run `rewind migrate` or pass --migrate."
      end
      Rewind.config.port = options[:port] if options[:port]
      Rewind.config.host = options[:host] if options[:host]
      Rewind.config.image_storage_dir = options[:image_storage_dir]
      app = Rewind.application
      Rewind::Services::Sync.start_thread
      Rewind::Services::Streaks.start_thread
      wildcard = %w[0.0.0.0 ::].include?(Rewind.config.host)
      display_host = wildcard ? "localhost" : Rewind.config.host
      say "Rewind listening on http://#{display_host}:#{Rewind.config.port}/"

      require "puma"
      require "puma/configuration"
      require "puma/launcher"

      plugins = %w[tmp_restart] | Rewind.config.puma_plugins
      conf = Puma::Configuration.new do |c|
        c.bind "tcp://#{Rewind.config.host}:#{Rewind.config.port}"
        c.app app
        plugins.each {|name| c.plugin(name) }
      end
      # Pass the original ARGV so Puma's restart (tmp_restart) re-execs the full
      # `rewind run ...` command instead of a bare `rewind`.
      Puma::Launcher.new(conf, argv: ARGV).run
    end
    map "run" => :run_server

    desc "restart", "Restart a running server (via Puma's tmp_restart plugin)"
    def restart
      path = File.join(Dir.pwd, "tmp", "restart.txt")
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.touch(path)
      say "Touched #{path}; a running server will restart."
    end

    desc "migrate", "Run all pending database migrations"
    def migrate
      CLI.load_env!(options[:env])
      require_relative "migrator"
      Rewind::Migrator.migrate!
      say "Migrations complete."
    end

    desc "sync", "Sync plays from enabled sources"
    option :source, type: :numeric,
                    desc: "Only sync this source id (default: all enabled)"
    option :verbose, type: :boolean, default: true, aliases: "-v",
                     desc: "Log per-source sync activity"
    option :reset, type: :boolean, default: false,
                   desc: "Delete synced + derived data and rebuild from " \
                         "scratch (ratings and reviews are kept)"
    option :yes, type: :boolean, default: false, aliases: "-y",
                 desc: "Skip the --reset confirmation prompt"
    def sync
      CLI.load_env!(options[:env])
      CLI.boot_db!
      Rewind.logger.level = Logger::INFO if options[:verbose]

      options[:reset] ? resync : sync_sources
    end

    no_commands do
      def sync_sources
        return sync_one(options[:source]) if options[:source]

        scope = Rewind::Source.where(enabled: true)
        count = scope.count
        abort("No enabled sources to sync.") if count.zero?

        Rewind::Services::Sync.run_once
        say "Synced #{count} #{count == 1 ? 'source' : 'sources'}."
      end

      def sync_one(id)
        source = Rewind::Source[id.to_i]
        abort("Source not found: #{id}") unless source

        Rewind::Services::Sync.sync_source(source)
        say "Synced source #{source.id} (#{source.url})."
      rescue StandardError => error
        abort("Sync failed for source #{source.id}: #{error.message}")
      end

      # --reset: wipe the synced + derived data and rebuild from scratch. Only
      # data we can re-fetch from Jellyfin is touched — ratings and reviews
      # (user_items) are never deleted.
      def resync
        scope = Rewind::Source.where(enabled: true)
        abort("No enabled sources to sync.") if scope.empty?
        confirm_reset!

        purge_synced_data
        scope.update(cursor: nil)
        Rewind::Services::Sync.run_once
        Rewind::Services::Streaks.rebuild_all
        say "Rebuilt from scratch. Ratings and reviews were kept."
      end

      def confirm_reset!
        return if options[:yes]

        say "This deletes all synced plays, items and streak data, then " \
            "re-syncs from your sources."
        say "Ratings and reviews are kept."
        abort("Aborted.") unless yes?("Continue? [y/N]")
      end

      def purge_synced_data
        Rewind.db.transaction do
          Rewind.db[:user_day_activity].delete
          Rewind::Play.dataset.delete
          Rewind::Item.dataset.delete
        end
      end
    end

    desc "console", "Launch an IRB console with models loaded"
    def console
      CLI.load_env!(options[:env])
      CLI.boot_db!
      require "irb"
      ARGV.clear
      IRB.start
    end

    desc "version", "Print the Rewind version"
    def version
      say Rewind::VERSION
    end

    desc "config", "Print the resolved configuration"
    def config_show
      CLI.load_env!(options[:env])
      Rewind.config.to_h.each do |k, v|
        display = v.nil? || (v.respond_to?(:empty?) && v.empty?) ? "(unset)" : v
        say format("  %-20s %s", "#{k}:", display)
      end
    end
    map "config" => :config_show

    desc "users SUBCOMMAND", "Manage users (new, update, delete, list)"
    subcommand "users", UsersCLI

    desc "sources SUBCOMMAND",
         "Manage sync sources (list, enable, disable, delete)"
    subcommand "sources", SourcesCLI

    desc "import SUBCOMMAND", "Import data from other services (trakt)"
    subcommand "import", ImportCLI

    def self.start(given_args = ARGV, config = {})
      # Allow colon form: users:new -> users new
      args = given_args.dup
      if args.first.is_a?(String) && args.first.include?(":")
        head, tail = args.shift.split(":", 2)
        args.unshift(head, tail)
      end
      super(args, config)
    end
  end
end
