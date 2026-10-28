# frozen_string_literal: true

require "httpx"
require "securerandom"

module Rewind
  module Services
    # Read/auth client for a Jellyfin instance.
    #
    # - `public_users` (unauthenticated) suggests users when linking an account.
    # - `authenticate` exchanges username/password for a per-user access token.
    # - `played_items` pages through a user's watched/listened history, newest
    #   first, stopping once it reaches the sync cursor.
    class Jellyfin
      Error = Class.new(Rewind::Error)
      AuthError = Class.new(Error)

      TIMEOUT = 8
      PAGE_SIZE = 100
      PLAYED_TYPES = "Movie,Episode,Audio,Video,MusicVideo"

      def self.public_users(url)
        new(url).public_users
      end

      def initialize(url, token: nil, device_id: nil, page_size: PAGE_SIZE)
        @url = self.class.normalize_url(url)
        @token = token
        # A per-source device id keeps tokens from clobbering each other.
        # Default to a random one (not a shared constant) so we can never emit a
        # colliding device id even if a caller forgets to pass one.
        @device_id = device_id || SecureRandom.hex(16)
        @page_size = page_size
      end

      def self.normalize_url(url)
        url.to_s.strip.sub(%r{/+\z}, "")
      end

      def public_users
        return [] if @url.empty?

        response = http.get("#{@url}/Users/Public")
        return [] if response.is_a?(HTTPX::ErrorResponse)
        return [] unless response.status.between?(200, 299)

        Array(JSON.parse(response.body.to_s)).filter_map do |user|
          id = user["Id"]
          name = user["Name"]
          {id:, name:} if id && name
        end
      rescue StandardError
        []
      end

      # Exchange credentials for an access token + Jellyfin user id.
      def authenticate(username:, password:)
        response = http(auth: client_auth_header).post(
          "#{@url}/Users/AuthenticateByName",
          json: {Username: username, Pw: password}
        )
        if response.is_a?(HTTPX::ErrorResponse)
          raise AuthError,
                "Jellyfin authentication failed: #{response.error.message}"
        end
        unless response.status.between?(200, 299)
          body = response.body.to_s.strip[0, 200]
          raise AuthError,
                "Jellyfin authentication failed (HTTP #{response.status})" \
                "#{": #{body}" unless body.empty?}"
        end

        data = JSON.parse(response.body.to_s)
        {
          access_token: data["AccessToken"], user_id: data.dig("User", "Id"),
          server_id: data["ServerId"]
        }
      end

      # Every played Movie/Episode/Audio for a user, newest first, newer than
      # `since` (a LastPlayedDate string cursor; nil = full history).
      def played_items(user_id:, since: nil)
        cutoff = parse_time(since)
        collected = dated_played_items(user_id, cutoff)

        # On an incremental sync the descending scan stops at the cutoff, before
        # it reaches IsPlayed items that have no DatePlayed (they sort last).
        # Pull those too so played-but-undated tracks aren't stranded — but only
        # ones on an album also played in this batch, so we have a session to
        # place them in and don't re-resolve the whole undated backlog every
        # sync. A full scan (no cutoff) already pages all the way down to them.
        if cutoff
          albums = {}
          seen = {}
          collected.each do |item|
            seen[item["Id"]] = true
            albums[item["ParentId"]] = true if item["ParentId"]
          end
          undated_played_items(user_id:).each do |item|
            next unless albums[item["ParentId"]]

            collected << item unless seen[item["Id"]]
          end
        end

        collected
      end

      # The descending-by-DatePlayed scan: newest first, stopping at the cutoff.
      private def dated_played_items(user_id, cutoff)
        collected = []
        start = 0

        loop do
          page = get_items(user_id, start)
          items = Array(page["Items"])
          break if items.empty?

          items.each do |item|
            played = parse_time(item.dig("UserData", "LastPlayedDate"))
            return collected if cutoff && played && played <= cutoff

            collected << item
          end

          start += items.size
          break if start >= page["TotalRecordCount"].to_i
          break if items.size < @page_size
        end

        collected
      end

      # IsPlayed items Jellyfin never stamped with a DatePlayed (e.g. clients
      # that set the played flag but skip the progress API). Ascending by
      # DatePlayed puts the undated rows first, so we collect the leading run
      # and stop at the first dated row — bounded by the number of undated
      # items, not the whole history.
      def undated_played_items(user_id:)
        collected = []
        start = 0

        loop do
          page = get_items(user_id, start, order: "Ascending")
          items = Array(page["Items"])
          break if items.empty?

          stop = false
          items.each do |item|
            if parse_time(item.dig("UserData", "LastPlayedDate"))
              stop = true
              break
            end
            collected << item
          end
          break if stop

          start += items.size
          break if start >= page["TotalRecordCount"].to_i
          break if items.size < @page_size
        end

        collected
      end

      # A single item's ProviderIds (used to resolve an episode's *series* TMDB
      # id, which the episode itself doesn't carry). Empty hash on failure.
      def provider_ids(user_id:, item_id:)
        response = get("#{@url}/Users/#{user_id}/Items/#{item_id}",
                       Fields: "ProviderIds")
        JSON.parse(response.body.to_s)["ProviderIds"] || {}
      rescue Error
        {}
      end

      # A single item (Name/Type/ImageTags), used to read a video's parent
      # folder. Empty hash on failure.
      def item(user_id:, item_id:)
        response = get("#{@url}/Users/#{user_id}/Items/#{item_id}")
        JSON.parse(response.body.to_s)
      rescue Error
        {}
      end

      # Whether an item still exists, as a tri-state so a transient failure is
      # never mistaken for a deletion: true (2xx), false (404 — the file is
      # gone), or :unknown (any other status / transport error). The re-tag
      # healer (Services::JellyfinArchive#reconcile) treats only a definitive
      # false as "re-tagged away" and absorbs on nothing else, so an outage
      # can't trigger a wrong merge.
      def item_present?(user_id:, item_id:)
        response = http(auth: token_auth_header)
                   .get("#{@url}/Users/#{user_id}/Items/#{item_id}")
        return :unknown if response.is_a?(HTTPX::ErrorResponse)

        case response.status
        when 200..299 then true
        when 404 then false
        else :unknown
        end
      end

      # Every Audio track belonging to an album, in disc/track order. Used to
      # backfill an album's unplayed tracks from a played one's parent. Empty
      # list on failure.
      def album_tracks(user_id:, album_id:)
        response = get(
          "#{@url}/Users/#{user_id}/Items",
          ParentId: album_id,
          IncludeItemTypes: "Audio",
          Recursive: true,
          SortBy: "ParentIndexNumber,IndexNumber,SortName",
          SortOrder: "Ascending",
          Fields: "ProviderIds,ParentIndexNumber,IndexNumber,RunTimeTicks," \
                  "PremiereDate,ProductionYear,Genres,AlbumArtists,Etag",
          Limit: 500
        )
        Array(JSON.parse(response.body.to_s)["Items"])
      rescue Error
        []
      end

      # Every album credited to an artist (by the artist's Jellyfin id), so an
      # artist's full discography can be backfilled from one played track. Empty
      # list on failure.
      def artist_albums(user_id:, artist_id:)
        response = get(
          "#{@url}/Users/#{user_id}/Items",
          AlbumArtistIds: artist_id,
          IncludeItemTypes: "MusicAlbum",
          Recursive: true,
          SortBy: "PremiereDate,ProductionYear,SortName",
          SortOrder: "Descending",
          Fields: "ProviderIds,PremiereDate,ProductionYear,Genres," \
                  "AlbumArtists,Etag",
          Limit: 500
        )
        Array(JSON.parse(response.body.to_s)["Items"])
      rescue Error
        []
      end

      # The album's release type + MusicBrainz ids, read from the file tags by
      # the AudioMetadata plugin. Jellyfin's own album payload often omits the
      # release (and sometimes the album artist) even for tagged files, so the
      # discography backfill and the rekey migration read them from the tracks
      # here. Returns {release_type:, release:, artist:, artist_name:, tracks:}
      # — tracks is [{item_id:, release_track:, recording:}] — the per-track
      # Jellyfin id, release-track mbid, and recording mbid. `artist`/
      # `artist_name` are the lead album-artist's id + name (first of a split
      # credit). Fields are nil / tracks empty when the plugin is absent, the
      # album is untagged, or the lookup fails — callers treat all as optional.
      def album_metadata(album_id)
        response = get("#{@url}/AudioMetadata/Album/#{album_id}")
        tracks = Array(JSON.parse(response.body.to_s)["Tracks"])
        raw = tracks.filter_map {|track| track["RawTags"] }

        {
          release_type: first_tag(tracks.map { it["ReleaseType"] })&.downcase,
          release: first_mbid(tracks.map { it["MusicBrainzAlbumId"] } +
                              raw.map { it["MUSICBRAINZ_ALBUMID"] }),
          artist: first_mbid(raw.map { it["MUSICBRAINZ_ALBUMARTISTID"] }),
          artist_name: first_name(raw.map { it["ALBUMARTISTS"] } +
                                  raw.map { it["ALBUMARTIST"] } +
                                  raw.map { it["ARTIST"] }),
          tracks: tracks.filter_map { album_track_entry(it) }
        }
      rescue Error
        {}
      end

      # {item_id:, release_track:, recording:} for one plugin track, or nil
      # without the id + release-track. The recording (the plugin's curated
      # MusicBrainzTrackId, or RawTags MUSICBRAINZ_TRACKID) is the id that
      # survives a re-tag, so the archive can tie a re-tagged file to its row.
      private def album_track_entry(track)
        item_id = first_tag([track["ItemId"]])
        raw = track["RawTags"] || {}
        release_track = first_mbid([raw["MUSICBRAINZ_RELEASETRACKID"]])
        recording = first_mbid(
          [track["MusicBrainzTrackId"], raw["MUSICBRAINZ_TRACKID"]]
        )
        {item_id:, release_track:, recording:} if item_id && release_track
      end

      # The album's MusicBrainz release type ("album"/"single"/"ep"/…), or nil.
      def album_release_type(album_id)
        album_metadata(album_id)[:release_type]
      end

      private def get_items(user_id, start_index, order: "Descending")
        response = get(
          "#{@url}/Users/#{user_id}/Items",
          IncludeItemTypes: PLAYED_TYPES,
          Recursive: true,
          Filters: "IsPlayed",
          SortBy: "DatePlayed",
          SortOrder: order,
          Fields: "ProviderIds,ParentIndexNumber,IndexNumber,SeriesId," \
                  "ParentId,DateCreated,PremiereDate,ProductionYear,Genres," \
                  "Path,Artists,AlbumArtists,Etag",
          Limit: @page_size,
          StartIndex: start_index
        )
        JSON.parse(response.body.to_s)
      end

      private def get(url, params = {})
        response = http(auth: token_auth_header).get(url, params: params)
        if response.is_a?(HTTPX::ErrorResponse) ||
           !response.status.between?(200, 299)
          status = response.respond_to?(:status) ? response.status : "error"
          raise AuthError, "Jellyfin request unauthorized" if status == 401

          raise Error, "Jellyfin request failed: #{status}"
        end

        response
      end

      private def http(auth: nil)
        headers = {"Accept" => "application/json"}
        headers["Authorization"] = auth if auth
        HTTPX.with(
          resolver_class: :system,
          timeout: {connect_timeout: TIMEOUT, operation_timeout: TIMEOUT},
          headers: headers
        )
      end

      private def client_auth_header
        device = %[Device="Rewind", DeviceId="#{@device_id}"]
        %[MediaBrowser Client="Rewind", #{device}, Version="#{Rewind::VERSION}"]
      end

      private def token_auth_header
        %[MediaBrowser Token="#{@token}"]
      end

      private def parse_time(value)
        return if value.nil? || value.to_s.strip.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      private def first_tag(values)
        values.map {|v| v.to_s.strip }.reject(&:empty?).first
      end

      # A RawTags id can carry several mbids joined by ';' or '/' (multi-artist
      # tracks); take the first non-empty one.
      private def first_mbid(values)
        raw = first_tag(values)
        return unless raw

        raw.split(%r{[;/]}).first.strip
      end

      # The first artist of a possibly multi-artist credit. Multi-artist tags
      # join names with ';'; take the first. Split on ';' ONLY (never '/'), so a
      # single artist whose name has a slash ("Bad Cop/Bad Cop") stays whole.
      private def first_name(values)
        raw = first_tag(values)
        raw && raw.split(";").first.strip
      end
    end
  end
end
