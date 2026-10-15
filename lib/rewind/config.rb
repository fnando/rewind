# frozen_string_literal: true

module Rewind
  class Config
    attr_accessor :data_dir, :tmdb_api_key, :session_secret, :host, :port

    def initialize
      @data_dir = ENV["REWIND_DATA_DIR"] || File.join(Dir.pwd, "data")
      @tmdb_api_key = ENV.fetch("TMDB_API_KEY", nil)
      @session_secret = ENV.fetch("REWIND_SESSION_SECRET", nil)
      @host = ENV["REWIND_HOST"] || "0.0.0.0"
      @port = (ENV["REWIND_PORT"] || 55_455).to_i
      @allowed_hosts = (ENV["REWIND_ALLOWED_HOSTS"] || "").split(",").map(&:strip).reject(&:empty?)
    end

    attr_accessor :allowed_hosts

    def db_path
      File.join(data_dir, "rewind.sqlite3")
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
      @styles_digest ||= Digest::MD5.hexdigest(File.read(File.join(public_dir,
                                                                   "styles.css")))
    end

    def to_h(redact: true)
      {
        data_dir: data_dir,
        db_path: db_path,
        host: host,
        port: port,
        tmdb_api_key: redact ? redact_value(tmdb_api_key) : tmdb_api_key,
        session_secret: redact ? redact_value(session_secret) : session_secret
      }
    end

    private def redact_value(value)
      return "(unset)" if value.nil? || value.empty?

      "[redacted]"
    end
  end
end
