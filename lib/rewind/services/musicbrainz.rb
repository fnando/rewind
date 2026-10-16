# frozen_string_literal: true

require "httpx"
require "digest"

module Rewind
  module Services
    # Resolves music plays into a cached artist -> album -> track chain of
    # Items, mirroring how TMDB.episode back-fills its show. Album art comes
    # from the Cover Art Archive; artist photos from fanart.tv.
    class MusicBrainz
      Error = Class.new(Rewind::Error)
      BASE_URL = "https://musicbrainz.org/ws/2"
      COVER_ART_URL = "https://coverartarchive.org"
      CACHE_TTL_DAYS = 7

      def initialize(user_agent: Rewind.config.musicbrainz_user_agent,
                     fanart: Fanart.new)
        @user_agent = user_agent
        @fanart = fanart
      end

      # Entry point for a scrobble: resolve by MusicBrainz id when the payload
      # carries one, otherwise search, and finally fall back to a synthetic
      # chain so an id-less play still records with its album/artist links.
      def resolve(artist:, album:, title:, mbid: nil, length_ms: nil)
        return if title.to_s.strip.empty?
        return recording(mbid) unless mbid.to_s.strip.empty?

        found = search_recording(artist: artist, album: album, title: title)
        return recording(found) if found

        build_synthetic(artist: artist, album: album, title: title,
                        length_ms: length_ms)
      end

      def recording(mbid)
        cache("mbid:#{mbid}", "track") do
          data = get("/recording/#{mbid}", inc: "artists+releases+genres",
                                           fmt: "json")
          track_attrs_from(data)
        end
      end

      private def track_attrs_from(data)
        artist_name, artist_mbid = artist_from(data)
        album_title, rg_mbid = album_from(data)
        artist = ensure_artist(artist_mbid, artist_name)
        album = ensure_album(rg_mbid, album_title, artist)

        {
          media_type: "track",
          external_id: "mbid:#{data['id']}",
          parent_external_id: album.external_id,
          title: data["title"],
          runtime: ms_to_minutes(data["length"]),
          poster_path: album.poster_path,
          metadata: track_metadata(artist, album, length_ms: data["length"],
                                                  genres: genres_from(data))
        }
      end

      private def build_synthetic(artist:, album:, title:, length_ms:)
        artist_item = ensure_artist(nil, artist)
        album_item = ensure_album(nil, album, artist_item)
        external_id = synthetic_id("track", "#{artist} #{album} #{title}")

        cache(external_id, "track") do
          {
            media_type: "track",
            external_id: external_id,
            parent_external_id: album_item.external_id,
            title: title,
            runtime: ms_to_minutes(length_ms),
            poster_path: album_item.poster_path,
            metadata: track_metadata(artist_item, album_item,
                                     length_ms: length_ms, genres: [])
          }
        end
      end

      private def ensure_artist(mbid, name)
        name = presence(name) || "Unknown Artist"
        external_id =
          mbid ? "mbid:artist:#{mbid}" : synthetic_id("artist", name)

        cache(external_id, "artist") do
          {
            media_type: "artist",
            external_id: external_id,
            title: name,
            poster_path: @fanart.artist_image(mbid)
          }
        end
      end

      private def ensure_album(mbid, title, artist)
        title = presence(title) || "Unknown Album"
        external_id =
          if mbid
            "mbid:rg:#{mbid}"
          else
            synthetic_id("album",
                         "#{artist.title} #{title}")
          end

        cache(external_id, "album") do
          {
            media_type: "album",
            external_id: external_id,
            parent_external_id: artist.external_id,
            title: title,
            poster_path: (cover_art_url(mbid) if mbid),
            metadata: {
              "artist" => artist.title,
              "artist_external_id" => artist.external_id
            }
          }
        end
      end

      private def track_metadata(artist, album, length_ms:, genres:)
        {
          "artist" => artist.title,
          "artist_external_id" => artist.external_id,
          "album" => album.title,
          "album_external_id" => album.external_id,
          "length_ms" => length_ms,
          "genres" => genres
        }
      end

      private def search_recording(artist:, album:, title:)
        query = [
          %[recording:"#{title}"],
          (%[artist:"#{artist}"] unless presence(artist).nil?),
          (%[release:"#{album}"] unless presence(album).nil?)
        ].compact.join(" AND ")

        data = get("/recording", query: query, fmt: "json", limit: 1)
        Array(data["recordings"]).first&.dig("id")
      rescue Error
        nil
      end

      private def artist_from(data)
        credit = Array(data["artist-credit"]).first || {}
        name = credit["name"] || credit.dig("artist", "name")
        [name, credit.dig("artist", "id")]
      end

      private def album_from(data)
        releases = Array(data["releases"])
        release = releases.find {|r| r["release-group"] } || releases.first
        return [nil, nil] unless release

        group = release["release-group"] || {}
        [group["title"] || release["title"], group["id"]]
      end

      private def genres_from(data)
        Array(data["genres"]).filter_map do |genre|
          name = genre.is_a?(Hash) ? genre["name"] : genre
          {"name" => name} if name
        end
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

      private def get(path, params = {})
        response = HTTPX
                   .with(headers: {
                           "User-Agent" => @user_agent,
                           "Accept" => "application/json"
                         })
                   .get("#{BASE_URL}#{path}", params: params)

        unless response.status.between?(200, 299)
          raise Error, "MusicBrainz request failed: #{response.status}"
        end

        JSON.parse(response.body.to_s)
      end
    end
  end
end
