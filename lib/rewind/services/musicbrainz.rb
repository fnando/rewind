# frozen_string_literal: true

require "digest"

module Rewind
  module Services
    # Builds a cached artist -> album -> track chain of Items from a scrobble.
    #
    # Identity comes straight from the payload: MusicBrainz ids when the library
    # is tagged, otherwise deterministic synthetic keys derived from the text
    # (artist, artist/album, artist/album/title). We never call the
    # MusicBrainz API — a lookup or search that intermittently hits or misses
    # (rate limiting) would split one song into a real item and a synthetic one.
    # Tagged and untagged copies of the same song may diverge into separate
    # items; that's accepted.
    #
    # Album art is a plain Cover Art Archive URL; artist photos come from
    # fanart.tv (one cached, best-effort call).
    class MusicBrainz
      COVER_ART_URL = "https://coverartarchive.org"
      CACHE_TTL_DAYS = 7

      def initialize(fanart: Fanart.new)
        @fanart = fanart
      end

      def resolve(title:, artist:, album:, recording_mbid: nil,
                  release_group_mbid: nil, artist_mbid: nil, length_ms: nil)
        return if presence(title).nil?

        artist_item = ensure_artist(artist_mbid, artist)
        album_item = ensure_album(release_group_mbid, album, artist_item)
        external_id =
          if presence(recording_mbid)
            "mbid:#{recording_mbid}"
          else
            synthetic_id("track", "#{artist}/#{album}/#{title}")
          end

        cache(external_id, "track") do
          {
            media_type: "track",
            external_id: external_id,
            parent_external_id: album_item.external_id,
            title: title,
            runtime: ms_to_minutes(length_ms),
            poster_path: album_item.poster_path,
            metadata: track_metadata(artist_item, album_item,
                                     length_ms: length_ms)
          }
        end
      end

      private def ensure_artist(mbid, name)
        name = presence(name) || "Unknown Artist"
        external_id =
          presence(mbid) ? "mbid:artist:#{mbid}" : synthetic_id("artist", name)

        cache(external_id, "artist") do
          {
            media_type: "artist",
            external_id: external_id,
            title: name,
            poster_path: @fanart.artist_image(presence(mbid))
          }
        end
      end

      private def ensure_album(mbid, title, artist)
        title = presence(title) || "Unknown Album"
        external_id =
          if presence(mbid)
            "mbid:rg:#{mbid}"
          else
            synthetic_id("album", "#{artist.title}/#{title}")
          end

        cache(external_id, "album") do
          {
            media_type: "album",
            external_id: external_id,
            parent_external_id: artist.external_id,
            title: title,
            poster_path: (cover_art_url(mbid) if presence(mbid)),
            metadata: {
              "artist" => artist.title,
              "artist_external_id" => artist.external_id
            }
          }
        end
      end

      private def track_metadata(artist, album, length_ms:)
        {
          "artist" => artist.title,
          "artist_external_id" => artist.external_id,
          "album" => album.title,
          "album_external_id" => album.external_id,
          "length_ms" => length_ms
        }
      end

      private def cover_art_url(rg_mbid)
        "#{COVER_ART_URL}/release-group/#{rg_mbid}/front-250"
      end

      private def ms_to_minutes(length_ms)
        return if length_ms.nil?

        (length_ms.to_i / 60_000.0).round
      end

      private def synthetic_id(kind, text)
        "mbid:synthetic:#{kind}:#{Digest::SHA256.hexdigest(text.to_s.downcase)}"
      end

      private def presence(value)
        str = value.to_s.strip
        str.empty? ? nil : str
      end

      private def cache(external_id, media_type)
        existing =
          Rewind::Item.where(media_type: media_type,
                             external_id: external_id).first
        cutoff = Time.now - (CACHE_TTL_DAYS * 86_400)
        return existing if existing&.fetched_at && existing.fetched_at > cutoff

        attrs = yield.merge(fetched_at: Time.now)

        if existing
          existing.update(attrs)
          existing
        else
          Rewind::Item.create(attrs)
        end
      end
    end
  end
end
