# frozen_string_literal: true

require "thor"
require "dotenv"

module Rewind
  class UsersCLI < Thor
    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"
    class_option :environment, aliases: "-e", type: :string,
                               desc: "Run environment (default: production)"

    def self.exit_on_failure?
      true
    end

    desc "new", "Create a new user with a generated password"
    option :username, type: :string, required: true
    option :name, type: :string
    def new
      Rewind::CLI.load_env!(options)
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
      Rewind::CLI.load_env!(options)
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
      Rewind::CLI.load_env!(options)
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
      Rewind::CLI.load_env!(options)
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
    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"
    class_option :environment, aliases: "-e", type: :string,
                               desc: "Run environment (default: production)"

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
        Rewind::CLI.load_env!(options)
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
    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"
    class_option :environment, aliases: "-e", type: :string,
                               desc: "Run environment (default: production)"

    def self.exit_on_failure?
      true
    end

    desc "trakt", "Import watchings, ratings, and reviews from a Trakt export"
    option :archive, type: :string, required: true,
                     desc: "Path to the Trakt data export .zip"
    option :username, type: :string, required: true,
                      desc: "User the imported data belongs to"
    def trakt
      Rewind::CLI.load_env!(options)
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

  class WebhooksCLI < Thor
    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"
    class_option :environment, aliases: "-e", type: :string,
                               desc: "Run environment (default: production)"

    def self.exit_on_failure?
      true
    end

    desc "new", "Mint a webhook secret (shown once)"
    option :name, type: :string, desc: "A label, e.g. the instance name"
    def new
      boot!
      record, secret = Rewind::Webhook.mint(name: options[:name])
      say "\n== Webhook created =="
      say "  id:    #{record.id}"
      say "  name:  #{record.name || '-'}"
      say "  path:  /webhooks/jellyfin/#{secret}"
      say "\nStore the secret now — it can't be shown again. Register your " \
          "host + that path in Jellyfin's webhook plugin."
    end

    desc "list", "List webhook secrets"
    def list
      boot!
      rows = Rewind::Webhook.order(:id).all
      return say "No webhooks yet. Run: rewind webhooks:new" if rows.empty?

      say "ID    NAME                 ENABLED  LAST USED"
      rows.each do |w|
        say format(
          "%-5s %-20s %-8s %-20s",
          w.id, w.name || "-", w.enabled ? "yes" : "no",
          w.last_used_at&.strftime("%Y-%m-%d %H:%M") || "never"
        )
      end
    end

    desc "rotate", "Replace a webhook's secret (shown once)"
    option :id, type: :numeric, required: true
    def rotate
      boot!
      webhook = find(options[:id])
      secret = webhook.rotate!
      say "Rotated webhook #{webhook.id}. New path: " \
          "/webhooks/jellyfin/#{secret}"
    end

    desc "revoke", "Disable a webhook without deleting it"
    option :id, type: :numeric, required: true
    def revoke
      boot!
      webhook = find(options[:id])
      webhook.update(enabled: false)
      say "Revoked webhook #{webhook.id}."
    end

    no_commands do
      def boot!
        Rewind::CLI.load_env!(options)
        Rewind::CLI.boot_db!
      end

      def find(id)
        webhook = Rewind::Webhook[id.to_i]
        abort("Webhook not found: #{id}") unless webhook
        webhook
      end
    end
  end

  # On-demand refreshes. The sync fetches each item once and skips it while
  # unchanged (fast, never stale for what it tracks), so these are the manual
  # path to re-pull data that grows or changes out of band — new albums for an
  # artist, new seasons of a show, or plays Jellyfin recorded without a date.
  class BackfillCLI < Thor
    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"
    class_option :environment, aliases: "-e", type: :string,
                               desc: "Run environment (default: production)"

    def self.exit_on_failure?
      true
    end

    desc "series", "Refresh TMDB series metadata (season posters, new seasons)"
    def series
      Rewind::CLI.load_env!(options)
      Rewind::CLI.boot_db!
      if Rewind.config.tmdb_api_key.to_s.empty?
        abort("TMDB_API_KEY not configured; nothing to backfill.")
      end

      tmdb = Rewind::Services::TMDB.new
      series = Rewind::Item.where(media_type: "series")
                           .where(Sequel.like(:external_id, "tmdb:%")).all
      say "Refreshing #{series.size} series…"
      done = 0
      series.each_with_index do |item, i|
        # Backdate so tv_item re-fetches instead of returning the cached row.
        item.update(fetched_at: Time.at(0))
        tmdb.tv_item(item.tmdb_id)
        done += 1
        say "  [#{i + 1}/#{series.size}] #{item.title}"
      rescue StandardError => error
        say "  [#{i + 1}/#{series.size}] skipped #{item.title}: " \
            "#{error.message}"
      end

      say "Refreshed #{done} of #{series.size} series."
    end

    desc "artist-albums", "Pull every known artist's full discography"
    def artist_albums
      Rewind::CLI.load_env!(options)
      Rewind::CLI.boot_db!

      sources = Rewind::Source.where(type: "jellyfin", enabled: true)
      abort("No enabled Jellyfin sources.") if sources.empty?

      done = 0
      sources.each do |source|
        say "Source #{source.id} (#{source.url})…"
        adapter = Rewind::Services::Sources::Jellyfin.new(source)
        done += adapter.backfill_known_artists_albums do |name, albums|
          say "  #{name} — #{albums} #{albums == 1 ? 'album' : 'albums'}"
        end
      rescue StandardError => error
        say "  source #{source.id} failed: #{error.message}"
      end

      say "Backfilled albums for #{done} artists."
    end

    desc "undated-plays", "Record played tracks Jellyfin left without a date"
    def undated_plays
      Rewind::CLI.load_env!(options)
      Rewind::CLI.boot_db!
      # Surface the pull/resolve timings as it works — a full scan is slow.
      Rewind.logger.level = Logger::INFO

      sources = Rewind::Source.where(type: "jellyfin", enabled: true)
      abort("No enabled Jellyfin sources.") if sources.empty?

      recovered = 0
      sources.each do |source|
        say "Source #{source.id} (#{source.url}): scanning full history…"
        adapter = Rewind::Services::Sources::Jellyfin.new(source)
        plays = adapter.recent_plays(since: nil)[:plays]
        written = plays.count do |play|
          Rewind::Services::Sync.record_play(source, play) == :written
        end
        recovered += written
        say "  recorded #{written} of #{plays.size} plays"
      rescue StandardError => error
        say "  source #{source.id} failed: #{error.message}"
      end

      say "Recorded #{recovered} missing #{recovered == 1 ? 'play' : 'plays'}."
    end
  end

  class CLI < Thor
    check_unknown_options!

    def self.exit_on_failure?
      true
    end

    # Loads an optional dotenv file, then resolves the run environment and
    # exports it as APP_ENV/RACK_ENV so Sinatra, Puma, and the app's own env
    # checks all agree — and so it applies before the app is loaded. The
    # --environment flag wins, else a file/shell APP_ENV|RACK_ENV, else
    # production. Runs for every command, not just `run`.
    def self.load_env!(options)
      path = options[:env_file]
      if path
        abort("env file not found: #{path}") unless File.exist?(path)
        Dotenv.load(path)
      end

      env = options[:environment] || ENV["APP_ENV"] || ENV["RACK_ENV"] ||
            "production"
      ENV["APP_ENV"] = env
      ENV["RACK_ENV"] = env
      Rewind.config = Config.new
    end

    def self.boot_db!
      require_relative "migrator"
      Rewind::Migrator.migrate! if ENV["REWIND_AUTO_MIGRATE"] == "1"
      Rewind.boot!
    end

    # The Logger level for the verbose options. Default is ERROR — quiet, but
    # failures still surface. --verbose-level sets it explicitly; --verbose/-v
    # is a shortcut for info. An explicit --verbose-level wins over --verbose.
    def self.resolve_log_level(options)
      level = options[:verbose_level] || (options[:verbose] && "info")
      case level
      when "debug" then Logger::DEBUG
      when "info" then Logger::INFO
      else Logger::ERROR
      end
    end

    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"
    class_option :environment, aliases: "-e", type: :string,
                               desc: "Run environment (default: production)"

    desc "run", "Start the Rewind web server"
    option :port, type: :numeric
    option :host, type: :string
    option :migrate, type: :boolean, default: false,
                     desc: "Run pending migrations before booting"
    option :verbose_level, type: :string, enum: %w[info debug],
                           desc: "Log verbosity: info or debug"
    option :verbose, type: :boolean, aliases: "-v",
                     desc: "Shortcut for --verbose-level=info"
    option :image_storage_dir, type: :string,
                               desc: "Directory to cache proxied cover images"
    option :workers, type: :numeric,
                     desc: "Number of Puma worker processes (0 = single mode)"
    option :threads, type: :numeric,
                     desc: "Number of Puma threads per worker"
    def run_server
      CLI.load_env!(options)
      Rewind.logger.level = CLI.resolve_log_level(options)
      require_relative "migrator"
      if options[:migrate] || ENV["REWIND_AUTO_MIGRATE"] == "1"
        Rewind::Migrator.migrate!
      elsif Rewind::Migrator.pending?
        abort "Pending migrations detected. " \
              "Run `rewind migrate` or pass --migrate."
      end
      Rewind.config.port = options[:port] if options[:port]
      Rewind.config.host = options[:host] if options[:host]
      Rewind.config.workers = options[:workers] if options[:workers]
      Rewind.config.threads = options[:threads] if options[:threads]
      Rewind.config.image_storage_dir = options[:image_storage_dir]
      app = Rewind.application
      wildcard = %w[0.0.0.0 ::].include?(Rewind.config.host)
      display_host = wildcard ? "localhost" : Rewind.config.host
      say "Rewind listening on http://#{display_host}:#{Rewind.config.port}/"

      conf = CLI.puma_configuration(app) # requires "puma" before the launcher
      require "puma/launcher"
      # Pass the original ARGV so Puma's restart (tmp_restart) re-execs the full
      # `rewind run ...` command instead of a bare `rewind`.
      launcher = Puma::Launcher.new(conf, argv: ARGV)
      # Start background loops once, in the master, AFTER any workers fork — so
      # forking never races a thread mid-write and they're never duplicated per
      # worker. after_booted fires in both single and cluster mode, but only on
      # the launcher's own events (config hooks target a different object).
      launcher.events.after_booted do
        Rewind::Services::Sync.start_thread
        Rewind::Services::Streaks.start_thread
        Rewind::Services::TimezoneData.start_thread
      end
      launcher.run
    end
    map "run" => :run_server

    # Builds the Puma configuration from Rewind's config. workers/threads of 0
    # are left at Puma's own defaults (single mode / default thread pool).
    def self.puma_configuration(app, config: Rewind.config)
      require "puma"
      require "puma/configuration"

      plugins = %w[tmp_restart] | config.puma_plugins
      Puma::Configuration.new do |c|
        c.bind "tcp://#{config.host}:#{config.port}"
        c.app app
        c.environment config.environment
        c.threads config.threads, config.threads if config.threads.positive?

        if config.workers.positive?
          c.workers config.workers
          # Drop the preloaded SQLite handle before forking so workers don't
          # share the master's connection; each reopens lazily on first query.
          c.before_fork { Rewind.db.disconnect }
        end

        plugins.each {|name| c.plugin(name) }
      end
    end

    desc "restart", "Restart a running server (via Puma's tmp_restart plugin)"
    def restart
      path = File.join(Dir.pwd, "tmp", "restart.txt")
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.touch(path)
      say "Touched #{path}; a running server will restart."
    end

    desc "migrate", "Run all pending database migrations"
    def migrate
      CLI.load_env!(options)
      require_relative "migrator"
      Rewind::Migrator.migrate!
      say "Migrations complete."
    end

    desc "dedupe-plays", "Collapse Jellyfin plays recorded by both the pull " \
                         "sync and the webhook (start vs stop). Idempotent."
    def dedupe_plays
      CLI.load_env!(options)
      CLI.boot_db!
      removed = Rewind::Services::PlayDedup.run
      say "Removed #{removed} duplicate #{removed == 1 ? 'play' : 'plays'}."
    end

    desc "sync", "Sync plays from enabled sources"
    option :source, type: :numeric,
                    desc: "Only sync this source id (default: all enabled)"
    option :verbose_level, type: :string, enum: %w[info debug],
                           desc: "Log verbosity: info or debug"
    option :verbose, type: :boolean, aliases: "-v",
                     desc: "Shortcut for --verbose-level=info"
    option :reset, type: :boolean, default: false,
                   desc: "Clear cursors and re-pull the full history, then " \
                         "rebuild streaks (non-destructive: deletes nothing)"
    def sync
      CLI.load_env!(options)
      CLI.boot_db!
      Rewind.logger.level = CLI.resolve_log_level(options)

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

      # --reset: re-pull the full history and rebuild derived data. It deletes
      # NOTHING — `plays` is an accumulated event log that Jellyfin does not
      # retain (it keeps only the latest LastPlayedDate per item), so wiping it
      # would be irreversible data loss. Clearing cursors refetches everything;
      # re-syncing refreshes item metadata and dedupes plays by source_event_id;
      # rebuilding recomputes streaks from the (intact) plays.
      def resync
        scope = Rewind::Source.where(enabled: true)
        abort("No enabled sources to sync.") if scope.empty?

        scope.update(cursor: nil)
        Rewind::Services::Sync.run_once
        Rewind::Services::Streaks.rebuild_all
        say "Re-pulled full history and rebuilt streaks. Nothing was deleted."
      end
    end

    desc "console", "Launch an IRB console with models loaded"
    def console
      CLI.load_env!(options)
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
      CLI.load_env!(options)
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

    desc "webhooks SUBCOMMAND", "Manage webhook secrets"
    subcommand "webhooks", WebhooksCLI

    desc "backfill SUBCOMMAND",
         "Refresh data on demand (series, artist-albums, undated-plays)"
    subcommand "backfill", BackfillCLI

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
