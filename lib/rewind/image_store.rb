# frozen_string_literal: true

module Rewind
  # Serves cached cover images straight off disk from the configured image
  # storage dir. Requests under /images/ whose file exists are served here with
  # a long immutable cache; misses fall through to the app, which fetches the
  # upstream image, writes it to the dir, and serves it once (routes/images).
  class ImageStore
    PREFIX = "/images/"
    CACHE_CONTROL = "public, max-age=31536000, immutable"

    def initialize(app)
      @app = app
    end

    def call(env)
      path = env["PATH_INFO"]
      return @app.call(env) unless get_or_head?(env) && path.start_with?(PREFIX)

      file = resolve(path)
      return @app.call(env) unless file && File.file?(file)

      serve(file, env)
    end

    private def get_or_head?(env)
      %w[GET HEAD].include?(env["REQUEST_METHOD"])
    end

    # Maps the request path to a file inside the storage dir, guarding against
    # path traversal. Returns nil if the cleaned path escapes the prefix.
    private def resolve(path)
      rel = Rack::Utils.unescape(path.delete_prefix(PREFIX))
      clean = Rack::Utils.clean_path_info(rel)
      return if clean.empty? || clean.include?("..")

      File.join(Rewind.config.image_storage_dir, clean)
    end

    private def serve(file, env)
      Rewind.logger.info("[images] hit #{File.basename(file)}")
      headers = {
        "content-type" => "image/jpeg",
        "content-length" => File.size(file).to_s,
        "cache-control" => CACHE_CONTROL
      }
      body = env["REQUEST_METHOD"] == "HEAD" ? [] : [File.binread(file)]
      [200, headers, body]
    end
  end
end
