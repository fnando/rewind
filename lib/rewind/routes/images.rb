# frozen_string_literal: true

require "base64"

module Rewind
  class Application < Sinatra::Base
    # Cache miss for a cover image: the path encodes the art owner, so every
    # item sharing a cover resolves here identically. Try each candidate
    # upstream in turn (stored poster_path, source-derived art, the item's own
    # Jellyfin artwork) until one returns bytes — a stored URL that 404s (e.g. a
    # release group with no Cover Art Archive cover) falls through to art that
    # does exist. Store the winner under the image dir so ImageStore serves it
    # from disk next time, heal poster_path to it, and return the bytes.
    get %r{/images/([A-Za-z0-9_-]+)\.jpg} do
      name = File.basename(request.path_info)
      media_type, external_id, size =
        decode_image_token(params[:captures].first)
      pass unless external_id

      if media_type == "season"
        item = nil
        stored = nil
        sources = [-> { season_poster_remote(external_id, size) }]
      else
        item = Item.where(media_type:, external_id:).first
        stored = item && remote_poster_url(item, size)
        # Lazy so derived art (a Fanart API call) only fires when the earlier
        # sources came up empty.
        sources = item ? poster_sources(item, stored) : []
      end

      remote = nil
      data = nil
      tried = false
      sources.each do |source|
        url = source.call
        next unless url

        tried = true
        Rewind.logger.info(
          "[images] miss #{media_type}:#{external_id}, downloading #{url}"
        )
        data = Services::ImageCache.fetch(url)
        if data
          remote = url
          break
        end
      end

      unless data
        reason =
          if tried then "no working cover source"
          elsif media_type != "season" && item.nil? then "unknown item"
          else "no cover source"
          end
        Rewind.logger.info("[images] miss #{media_type}:#{external_id} — " \
                           "#{reason}, serving placeholder")
        next placeholder_redirect
      end

      store_image(name, data)
      # Persist the URL that actually served so a dead/empty poster_path heals
      # and the fast path skips the failing fetch next time.
      if item && (item.poster_path.to_s.empty? || remote != stored)
        item.update(poster_path: remote)
      end
      Rewind.logger.info("[images] stored #{media_type}:#{external_id} " \
                         "(#{data.bytesize} bytes)")

      cache_control :public, max_age: 31_536_000
      content_type "image/jpeg"
      data
    end

    # Ordered, lazily-evaluated upstream candidates for an item's cover, best
    # first: its stored poster_path, then source-derived art (Cover Art Archive
    # / fanart.tv) for a late-arriving key, then the item's own Jellyfin artwork
    # — the only source for music that never matched MusicBrainz (synthetic ids)
    # or whose release group has no Cover Art Archive cover.
    private def poster_sources(item, stored)
      [
        -> { stored },
        -> { derived_poster_url(item) },
        -> { jellyfin_poster_url(item) }
      ]
    end

    private def derived_poster_url(item)
      case item.media_type
      when "artist"
        mbid = strip_mbid(item.external_id, "mbid:artist:")
        mbid && Services::Fanart.new.artist_image(mbid)
      when "album"
        mbid = strip_mbid(item.external_id, "mbid:rg:")
        mbid && "https://coverartarchive.org/release-group/#{mbid}/front-250"
      end
    end

    # The item's primary image on the configured Jellyfin source, by its stable
    # Jellyfin id. The host is resolved from the source (not baked in), matching
    # how remote_poster_url re-hosts Jellyfin paths.
    private def jellyfin_poster_url(item)
      id = item.jellyfin_id.to_s
      return if id.empty?

      base = jellyfin_source_url
      base && "#{base}/Items/#{id}/Images/Primary"
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
