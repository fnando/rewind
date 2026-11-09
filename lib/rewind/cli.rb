# frozen_string_literal: true

require "thor"
require "dotenv"

module Rewind
  class UsersCLI < Thor
    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"

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

    def self.exit_on_failure?
      true
    end

    LIST_FORMAT = "%-5s %-10s %-40s %-20s %-8s %-18s"

    desc "list", "List connected sync sources"
    def list
      boot!
      rows = Rewind::Source.order(:user_id, :type, :url).all
      if rows.empty?
        say "No sources connected. Users connect Jellyfin from Settings."
        return
      end

      say format(LIST_FORMAT, "ID", "TYPE", "URL", "USER", "ENABLED",
                 "LAST SYNC")
      rows.each do |source|
        say format(
          LIST_FORMAT,
          source.id,
          source.type,
          source.url,
          source.external_user_name || source.external_user_id,
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

  # On-demand refreshes. The sync fetches each item once and skips it while
  # unchanged (fast, never stale for what it tracks), so these are the manual
  # path to re-pull data that grows or changes out of band — new albums for an
  # artist, or new seasons of a show.
  class BackfillCLI < Thor
    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"

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

      sources = Rewind::Source.where(type: "jellyfin", enabled: true).all
      abort("No enabled Jellyfin sources.") if sources.empty?

      # The discography is global per server, so one account per Jellyfin
      # instance is enough — extra accounts on the same instance would just redo
      # identical work. (A nil instance_id can't be deduped; keep those.)
      sources = sources.uniq {|source| source.instance_id || source.id.to_s }

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

      pruned = Rewind::Services::Sources::Jellyfin.prune_orphaned_albums
      say "Backfilled albums for #{done} artists."
      say "Removed #{pruned} stale #{pruned == 1 ? 'album' : 'albums'}."
    end

    desc "rekey-music", "Re-key albums/tracks to release + release-track ids"
    long_desc <<~TEXT
      One-time migration: re-keys every album to its MusicBrainz release and
      every track to its release-track, reading the ids from the AudioMetadata
      plugin and matching rows by Jellyfin id. Plays and ratings are preserved;
      stale rows the plugin doesn't know are left alone. Run with sync paused.
    TEXT
    def rekey_music
      Rewind::CLI.load_env!(options)
      Rewind::CLI.boot_db!

      sources = Rewind::Source.where(type: "jellyfin", enabled: true).all
      abort("No enabled Jellyfin sources.") if sources.empty?
      # One library per server; one account per instance is enough.
      sources = sources.uniq {|source| source.instance_id || source.id.to_s }

      sources.each do |source|
        say "Source #{source.id} (#{source.url})…"
        client = Rewind::Services::Jellyfin.new(source.url,
                                                token: source.access_token,
                                                device_id: source.device_id)
        summary = Rewind::Services::MusicRekey.new(client:).run {|e| say "  #{e}" }
        say "  albums: #{summary.albums_rekeyed} re-keyed, " \
            "#{summary.albums_pruned} pruned, #{summary.skipped} skipped. " \
            "tracks: #{summary.tracks_rekeyed} re-keyed, " \
            "#{summary.items_absorbed} merged."
        say "  plays: #{summary.plays_moved} moved, " \
            "#{summary.plays_dropped} duplicates dropped."
        unless summary.drift.empty?
          say "  WARNING drift: #{summary.drift.inspect}"
        end
      rescue StandardError => error
        say "  source #{source.id} failed: #{error.message}"
      end
    end
  end

  # Admin fixes for the music library's identity model. Untagged files resolve
  # to synthetic ids, so one real artist can end up stored twice (synthetic +
  # mbid); `merge` collapses the two by hand, moving every play and rating.
  class ArtistsCLI < Thor
    class_option :env_file, type: :string,
                            desc: "Dotenv file to load before executing"

    def self.exit_on_failure?
      true
    end

    desc "merge", "Merge one artist (and its albums/tracks) into another"
    long_desc <<~TEXT
      Collapses the --from artist onto --to, matching albums and tracks by name,
      moving plays and ratings, and recording the mapping so future untagged
      plays route to the real artist. It also de-duplicates the target's own
      albums (a synthetic album onto its mbid twin of the same name) — so if an
      album's mbid twin was synced only after an earlier merge re-parented it,
      pass the SAME id for --from and --to to collapse it now. --from/--to are
      the item ids in the /items/:id URL. Destructive — run with sync paused.
    TEXT
    option :from, type: :numeric, required: true,
                  desc: "Item id to merge FROM (usually the synthetic artist)"
    option :to, type: :numeric, required: true,
                desc: "Item id to merge INTO (the real MusicBrainz artist)"
    def merge
      Rewind::CLI.load_env!(options)
      Rewind::CLI.boot_db!

      from = Rewind::Item[options[:from].to_i]
      to = Rewind::Item[options[:to].to_i]
      abort("No item with id #{options[:from].to_i}") unless from
      abort("No item with id #{options[:to].to_i}") unless to

      if from.id == to.id
        say "De-duplicating albums under #{to.title.inspect} (##{to.id})…"
      else
        say "Merging #{from.title.inspect} (##{from.id}) into " \
            "#{to.title.inspect} (##{to.id})…"
      end
      summary =
        begin
          Rewind::Services::MusicMerge.new(from:, to:).run {|event| say event }
        rescue Rewind::Services::MusicMerge::Error => error
          abort("Merge aborted: #{error.message}")
        end

      say ""
      say "Done. albums: #{summary.albums_merged} merged, " \
          "#{summary.albums_reparented} kept; tracks: " \
          "#{summary.tracks_merged} merged, #{summary.tracks_reparented} kept."
      say "Plays: #{summary.plays_repointed} moved, " \
          "#{summary.plays_dropped} duplicates dropped. " \
          "Ratings/reviews migrated: #{summary.user_items_migrated} " \
          "(#{summary.rating_conflicts} rating conflicts)."
      say "Map entries written: #{summary.map_entries}."
      return if summary.drift.empty?

      say "WARNING: streak drift detected — #{summary.drift.inspect}"
    end
  end

  class CLI < Thor
    check_unknown_options!

    def self.exit_on_failure?
      true
    end

    # Loads an optional dotenv file, then rebuilds the config from it. The run
    # environment is whatever APP_ENV/RACK_ENV say (from the file or shell),
    # read directly by Sinatra (Rewind::Application.development?/production?)
    # and Config — so there's no flag and nothing to keep in sync. Runs for
    # every command, not just `run`.
    def self.load_env!(options)
      path = options[:env_file]
      if path
        abort("env file not found: #{path}") unless File.exist?(path)
        Dotenv.load(path)
      end

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

    desc "sync", "Sync plays from enabled sources"
    option :source, type: :numeric,
                    desc: "Only sync this source id (default: all enabled)"
    option :verbose_level, type: :string, enum: %w[info debug],
                           desc: "Log verbosity: info or debug"
    option :verbose, type: :boolean, aliases: "-v",
                     desc: "Shortcut for --verbose-level=info"
    option :reset, type: :boolean, default: false,
                   desc: "Delete the Jellyfin plays and re-import the full " \
                         "history from the Rewind plugin, then rebuild streaks"
    option :yes, type: :boolean, default: false,
                 desc: "Don't ask for confirmation with --reset"
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

      # --reset: start over from the Rewind plugin. Deletes the plays imported
      # from the selected sources (every enabled one, or --source) and
      # re-imports their full history from the plugin's changes feed. Ratings,
      # reviews, items and plays from other origins (Trakt, manual) are kept.
      def resync
        scope = Rewind::Source.where(enabled: true)
        scope = scope.where(id: options[:source].to_i) if options[:source]
        sources = scope.all
        abort("No enabled sources to sync.") if sources.empty?
        confirm_reset!(sources)

        removed = Rewind::Services::Sync.reset(sources)
        sources.each do |source|
          Rewind::Services::Sync.sync_source(source)
        rescue StandardError => error
          say "Sync failed for source #{source.id}: #{error.message}"
        end
        Rewind::Services::Streaks.rebuild_all
        imported = Rewind::Play.where(source_id: sources.map(&:id)).count
        say "Removed #{removed} and imported #{imported} plays; " \
            "rebuilt streaks."
      end

      def confirm_reset!(sources)
        return if options[:yes]

        ids = sources.map(&:id).join(", ")
        print "Delete every play imported from source #{ids} and " \
              "re-import from the Rewind plugin? [y/N] "
        answer = $stdin.gets.to_s.strip.downcase
        abort("Aborted.") unless %w[y yes].include?(answer)
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

    desc "backfill SUBCOMMAND",
         "Refresh data on demand (series, artist-albums)"
    subcommand "backfill", BackfillCLI

    desc "artists SUBCOMMAND", "Music artist admin fixes (merge)"
    subcommand "artists", ArtistsCLI

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
