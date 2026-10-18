# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    # Cache miss for a cover image: fetch the upstream poster, store it under
    # the image storage dir so ImageStore serves it from disk next time, and
    # return the bytes for this request. Falls back to placeholder on failure.
    get %r{/images/(\d+)-(w\d+|original)-[0-9a-f]{8}\.jpg} do
      item_id, size = params[:captures]
      name = File.basename(request.path_info)
      item = Item[item_id.to_i]
      remote = item && remote_poster_url(item, size)
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
