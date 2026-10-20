# frozen_string_literal: true

require "base64"

module Rewind
  class Application < Sinatra::Base
    # Cache miss for a cover image: the path encodes the art owner, so every
    # item sharing a cover resolves here identically. Resolve the upstream URL
    # (stored, else re-derived), fetch it, store it under the image storage dir
    # so ImageStore serves it from disk next time, backfill the item so it
    # self-heals, and return the bytes. Placeholder on any failure.
    get %r{/images/([A-Za-z0-9_-]+)\.jpg} do
      name = File.basename(request.path_info)
      media_type, external_id, size =
        decode_image_token(params[:captures].first)
      pass unless external_id

      if media_type == "season"
        item = nil
        remote = season_poster_remote(external_id, size)
      else
        item = Item.where(media_type:, external_id:).first
        remote = item && resolve_poster_remote(item, size)
      end
      unless remote
        unknown = media_type != "season" && item.nil?
        reason = unknown ? "unknown item" : "no cover source"
        Rewind.logger.info("[images] miss #{media_type}:#{external_id} — " \
                           "#{reason}, serving placeholder")
        next placeholder_redirect
      end

      Rewind.logger.info(
        "[images] miss #{media_type}:#{external_id}, downloading #{remote}"
      )
      data = Services::ImageCache.fetch(remote)
      unless data
        Rewind.logger.info("[images] #{media_type}:#{external_id} fetch " \
                           "failed, serving placeholder")
        next placeholder_redirect
      end

      store_image(name, data)
      item.update(poster_path: remote) if item && item.poster_path.to_s.empty?
      Rewind.logger.info("[images] stored #{media_type}:#{external_id} " \
                         "(#{data.bytesize} bytes)")

      cache_control :public, max_age: 31_536_000
      content_type "image/jpeg"
      data
    end

    # The upstream URL for an item's cover: its stored poster_path if present,
    # otherwise re-derived from the source (Cover Art Archive / fanart.tv) so a
    # late-arriving key or image is picked up without a re-sync.
    private def resolve_poster_remote(item, size)
      stored = remote_poster_url(item, size)
      return stored if stored

      case item.media_type
      when "artist"
        mbid = strip_mbid(item.external_id, "mbid:artist:")
        mbid && Services::Fanart.new.artist_image(mbid)
      when "album"
        mbid = strip_mbid(item.external_id, "mbid:rg:")
        mbid && "https://coverartarchive.org/release-group/#{mbid}/front-250"
      end
    end

    # The upstream URL for a TV season's poster, which lives in its series'
    # stored metadata rather than an Item of its own. The season has no row to
    # backfill, so it re-resolves from that metadata on each miss and persists
    # only as the cached file. external_id is "<series external_id>:<number>".
    private def season_poster_remote(external_id, size)
      series_external_id, _, number = external_id.rpartition(":")
      return if series_external_id.empty?

      series = Item.where(media_type: "series",
                          external_id: series_external_id).first
      return unless series

      season = Array(series.metadata["seasons"]).find do |s|
        s["season_number"].to_i == number.to_i
      end
      path = season && season["poster_path"].to_s
      return if path.to_s.empty?

      "https://image.tmdb.org/t/p/#{size}#{path}"
    end

    private def strip_mbid(external_id, prefix)
      id = external_id.to_s
      id.start_with?(prefix) ? id.delete_prefix(prefix) : nil
    end

    # Decodes "<media_type>:<external_id>:<size>"; external_id itself may hold
    # colons, so split off the known first/last fields and rejoin the middle.
    private def decode_image_token(token)
      padded = token + ("=" * ((4 - (token.length % 4)) % 4))
      parts = Base64.urlsafe_decode64(padded).split(":")
      return if parts.size < 3

      [parts.first, parts[1..-2].join(":"), parts.last]
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
      cache_control :public, max_age: 60
      redirect "/poster-placeholder.svg"
    end
  end
end
