# frozen_string_literal: true

require "base64"

module Rewind
  class Application < Sinatra::Base
    # Cache miss for a cover image: the path is the base64 upstream URL, so
    # every item sharing a cover resolves here identically. Fetch it, store it
    # under the image storage dir so ImageStore serves it from disk next time,
    # and return the bytes. Falls back to placeholder on failure.
    get %r{/images/([A-Za-z0-9_-]+)\.jpg} do
      name = File.basename(request.path_info)
      remote = decode_image_token(params[:captures].first)
      pass unless remote

      Rewind.logger.info("[images] miss #{name}, downloading #{remote}")
      data = Services::ImageCache.fetch(remote)
      unless data
        Rewind.logger.info("[images] #{name} unavailable, serving placeholder")
        next placeholder_redirect
      end

      store_image(name, data)
      Rewind.logger.info("[images] stored #{name} (#{data.bytesize} bytes)")

      cache_control :public, max_age: 31_536_000
      content_type "image/jpeg"
      data
    end

    # Decodes the base64url token back into the upstream URL. The actual SSRF
    # guard is the host allowlist in Services::ImageCache.
    private def decode_image_token(token)
      padded = token + ("=" * ((4 - (token.length % 4)) % 4))
      url = Base64.urlsafe_decode64(padded)
      url if url.start_with?("https://")
    rescue ArgumentError
      nil
    end

    private def store_image(name, data)
      dir = Rewind.config.image_storage_dir
      FileUtils.mkdir_p(dir)
      path = File.join(dir, name)
      tmp = "#{path}.#{SecureRandom.hex(4)}.tmp"
      File.binwrite(tmp, data)
      File.rename(tmp, path)
    end

    private def placeholder_redirect
      cache_control :public, max_age: 300
      redirect "/poster-placeholder.svg"
    end
  end
end
