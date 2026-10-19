# frozen_string_literal: true

module Rewind
  class Config
    attr_accessor :data_dir, :tmdb_api_key, :fanart_api_key,
                  :session_secret, :host, :port, :keyring, :sync_interval,
                  :streak_rebuild_interval, :allowed_hosts, :puma_plugins,
                  :db_busy_timeout, :workers, :threads, :environment
    attr_writer :image_storage_dir

    def initialize
      @data_dir = ENV["REWIND_DATA_DIR"] || File.join(Dir.pwd, "data")
      @tmdb_api_key = ENV.fetch("TMDB_API_KEY", nil)
      @fanart_api_key = ENV.fetch("FANART_API_KEY", nil)
      @session_secret = ENV.fetch("REWIND_SESSION_SECRET", nil)
      @keyring = parse_keyring(ENV.fetch("REWIND_KEYRING", nil))
      @sync_interval = (ENV["REWIND_SYNC_INTERVAL"] || 60).to_i
      # Self-healing rebuild of the derived streak table. Hooks keep it in sync
      # on every write, but if it ever drifts we'd show a *broken* streak — the
      # worst failure for this feature — so the heal runs every few minutes to
      # keep any drift window small. Also picks up time-zone / media-type edits.
      @streak_rebuild_interval =
        (ENV["REWIND_STREAK_REBUILD_INTERVAL"] || 300).to_i
      # How long a blocked SQLite writer waits before raising "database is
      # locked" (ms). Generous so the web app's background sync/streak threads
      # and a concurrent `sync` take turns instead of failing.
      @db_busy_timeout = (ENV["REWIND_DB_BUSY_TIMEOUT"] || 15_000).to_i
      @host = ENV["REWIND_HOST"] || "0.0.0.0"
      @port = (ENV["REWIND_PORT"] || 55_455).to_i
      # Puma sizing. 0 means "leave Puma's own default" — workers 0 is single
      # mode; threads 0 keeps Puma's default thread pool.
      @workers = (ENV["REWIND_WORKERS"] || 0).to_i
      @threads = (ENV["REWIND_THREADS"] || 0).to_i
      # Rack/Puma run environment. Defaults to production; APP_ENV/RACK_ENV (the
      # vars Sinatra and Puma read on their own) act as fallbacks.
      @environment = ENV["APP_ENV"] || ENV["RACK_ENV"] || "production"
      @allowed_hosts =
        (ENV["REWIND_ALLOWED_HOSTS"] || "")
        .split(",").map(&:strip).reject(&:empty?)
      @puma_plugins =
        (ENV["REWIND_PUMA_PLUGINS"] || "")
        .split(",").map(&:strip).reject(&:empty?)
    end

    # The attr_keyring keyring ({id => base64 key}) used to encrypt source
    # credentials. Required before a source can be saved.
    def require_keyring!
      return unless keyring.empty?

      raise Rewind::Error,
            "REWIND_KEYRING must be set (JSON of encryption keys) to store " \
            "source credentials"
    end

    private def parse_keyring(value)
      return {} if value.to_s.strip.empty?

      JSON.parse(value)
    rescue JSON::ParserError => error
      raise Rewind::Error,
            "REWIND_KEYRING is not valid JSON — expected " \
            "{\"1\":\"<base64 32-byte key>\"} (#{error.message})"
    end

    def db_path
      File.join(data_dir, "rewind.sqlite3")
    end

    def image_storage_dir
      @image_storage_dir || File.join(data_dir, "images")
    end

    def avatars_dir
      File.join(data_dir, "avatars")
    end

    def avatar_path(user_id)
      File.join(avatars_dir, "#{user_id}.jpg")
    end

    def session_secret_path
      File.join(data_dir, ".session_secret")
    end

    def resolved_session_secret
      return session_secret if session_secret && !session_secret.empty?

      path = session_secret_path
      if File.exist?(path)
        File.read(path).strip
      else
        FileUtils.mkdir_p(data_dir)
        secret = SecureRandom.hex(64)
        File.write(path, secret)
        File.chmod(0o600, path)
        secret
      end
    end

    def migrations_dir
      File.join(Rewind.root, "lib", "rewind", "db", "migrations")
    end

    def views_dir
      File.join(Rewind.root, "lib", "rewind", "views")
    end

    def public_dir
      File.join(Rewind.root, "lib", "rewind", "public")
    end

    def styles_digest
      path = File.join(public_dir, "styles.css")
      @styles_digest ||= Digest::MD5.hexdigest(File.read(path))
    end

    def to_h(redact: true)
      {
        data_dir: data_dir,
        db_path: db_path,
        host: host,
        port: port,
        tmdb_api_key: redact ? redact_value(tmdb_api_key) : tmdb_api_key,
        session_secret: redact ? redact_value(session_secret) : session_secret,
        keyring: keyring.empty? ? "(unset)" : "[#{keyring.size} key(s)]",
        sync_interval: sync_interval,
        streak_rebuild_interval: streak_rebuild_interval
      }
    end

    private def redact_value(value)
      return "(unset)" if value.nil? || value.empty?

      "[redacted]"
    end
  end
end
