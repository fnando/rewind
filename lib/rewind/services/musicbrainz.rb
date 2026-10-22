# frozen_string_literal: true

require "digest"

module Rewind
  module Services
    # Builds an artist -> album -> track chain of Items from a scrobble.
    #
    # Identity comes straight from the payload: MusicBrainz ids when the library
    # is tagged, otherwise deterministic synthetic keys derived from the text
    # (artist, artist/album, artist/album/title). We never call the
    # MusicBrainz API — a lookup or search that intermittently hits or misses
    # (rate limiting) would split one song into a real item and a synthetic one.
    # Tagged and untagged copies of the same song may diverge into separate
    # items; that's accepted.
    #
    # Every resolve upserts the row from the data in hand (cheap, local SQLite),
    # so fields like track/disc number stay current — no time-based cache to go
    # stale. The one genuinely remote piece is the artist photo (fanart.tv); we
    # reuse a stored one instead of re-fetching, so a full-album backfill never
    # hits fanart once per track. Album art is a plain Cover Art Archive URL.
    class MusicBrainz
      COVER_ART_URL = "https://coverartarchive.org"

      def initialize(fanart: Fanart.new)
        @fanart = fanart
      end

      # The external_id for a real MusicBrainz id, by kind. One source of truth
      # for the id format, shared with the merge (Services::MusicMerge) that
      # collapses synthetic items onto these. Identity is release-scoped: an
      # album is its release, a track its release-track — so editions stay
      # distinct and a song shared across editions is one row per release. We
      # never key on the release group (too coarse) or the recording (shared
      # across editions).
      def self.track_external_id(release_track_mbid)
        "mbid:rt:#{release_track_mbid}" if presence(release_track_mbid)
      end

      def self.album_external_id(release_mbid)
        "mbid:release:#{release_mbid}" if presence(release_mbid)
      end

      def self.presence(value)
        str = value.to_s.strip
        str.empty? ? nil : str
      end

      def self.artist_external_id(artist_mbid)
        "mbid:artist:#{artist_mbid}"
      end

      def resolve(title:, artist:, album:, release_track_mbid: nil,
                  release_mbid: nil, artist_mbid: nil,
                  length_ms: nil, track_number: nil, disc_number: nil,
                  release_date: nil, genres: nil, jellyfin_id: nil,
                  album_jellyfin_id: nil)
        return if presence(title).nil?

        artist_item = ensure_artist(artist_mbid, artist)
        album_item = ensure_album(release_mbid, album, artist_item,
                                  release_date:, genres:,
                                  jellyfin_id: album_jellyfin_id)
        external_id =
          self.class.track_external_id(release_track_mbid) ||
          canonical(synthetic_id("track", "#{artist}/#{album}/#{title}"))

        upsert(external_id, "track") do |existing|
          {
            media_type: "track",
            external_id: external_id,
            parent_external_id: album_item.external_id,
            title: title,
            runtime: ms_to_minutes(length_ms),
            poster_path: album_item.poster_path,
            jellyfin_id: presence(jellyfin_id) || existing&.jellyfin_id,
            metadata: track_metadata(artist_item, album_item,
                                     length_ms: length_ms,
                                     track_number: track_number,
                                     disc_number: disc_number)
          }
        end
      end

      # Build the artist -> album chain from an album payload alone (no track),
      # so an artist's full discography can be listed even for albums the user
      # never played. Returns the album Item, or nil without a title.
      def resolve_album(title:, artist:, release_mbid: nil, artist_mbid: nil,
                        release_date: nil, genres: nil, jellyfin_id: nil)
        return if presence(title).nil?

        artist_item = ensure_artist(artist_mbid, artist)
        ensure_album(release_mbid, title, artist_item,
                     release_date:, genres:, jellyfin_id:)
      end

      private def ensure_artist(mbid, name)
        name = presence(name) || "Unknown Artist"
        external_id =
          if presence(mbid)
            self.class.artist_external_id(mbid)
          else
            canonical(synthetic_id("artist", name))
          end

        upsert(external_id, "artist") do |existing|
          {
            media_type: "artist",
            external_id: external_id,
            title: name,
            # The only remote call: skip it once we already have a photo.
            poster_path: existing&.poster_path ||
              @fanart.artist_image(presence(mbid))
          }
        end
      end

      private def ensure_album(release_mbid, title, artist,
                               release_date: nil, genres: nil, jellyfin_id: nil)
        title = presence(title) || "Unknown Album"
        external_id =
          self.class.album_external_id(release_mbid) ||
          canonical(synthetic_id("album", "#{artist.title}/#{title}"))

        upsert(external_id, "album") do |existing|
          genres = Array(genres).filter_map {|g| presence(g) }
          genres = Array(existing&.metadata&.dig("genres")) if genres.empty?
          {
            media_type: "album",
            external_id: external_id,
            parent_external_id: artist.external_id,
            title: title,
            # Tracks on an album share its year/genres/id; keep any we already
            # have when a given track's payload is missing them.
            release_date: presence(release_date) || existing&.release_date,
            jellyfin_id: presence(jellyfin_id) || existing&.jellyfin_id,
            poster_path: cover_art_url(release_mbid),
            metadata: {
              "artist" => artist.title,
              "artist_external_id" => artist.external_id,
              "genres" => genres
            }
          }
        end
      end

      private def track_metadata(artist, album, length_ms:, track_number: nil,
                                 disc_number: nil)
        {
          "artist" => artist.title,
          "artist_external_id" => artist.external_id,
          "album" => album.title,
          "album_external_id" => album.external_id,
          "length_ms" => length_ms,
          "track_number" => track_number,
          "disc_number" => disc_number
        }
      end

      # Cover Art Archive art for the album's release. nil without a release.
      private def cover_art_url(release_mbid)
        return unless presence(release_mbid)

        "#{COVER_ART_URL}/release/#{release_mbid}/front-250"
      end

      private def ms_to_minutes(length_ms)
        return if length_ms.nil?

        (length_ms.to_i / 60_000.0).round
      end

      private def synthetic_id(kind, text)
        "mbid:synthetic:#{kind}:#{Digest::SHA256.hexdigest(text.to_s.downcase)}"
      end

      # Follow the synthetic -> canonical merge map (Services::MusicMerge writes
      # it) to the final id, so a play that would re-mint a merged-away
      # synthetic id lands on its mbid twin instead of resurrecting the
      # duplicate. Only synthetic ids are ever keys, so callers apply this on
      # the synthetic branch alone. The visited set stops a cycle from hanging.
      private def canonical(external_id)
        seen = Set.new
        current = external_id
        until seen.include?(current)
          seen << current
          nxt = Rewind.db[:item_merges]
                      .where(from_external_id: current).get(:to_external_id)
          break unless nxt

          current = nxt
        end
        current
      end

      private def presence(value)
        str = value.to_s.strip
        str.empty? ? nil : str
      end

      # Upsert the item from the data in hand. The block receives the existing
      # row (or nil) so it can preserve values that are expensive to refetch.
      private def upsert(external_id, media_type)
        existing =
          Rewind::Item.where(media_type: media_type,
                             external_id: external_id).first
        attrs = yield(existing).merge(fetched_at: Time.now)

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
