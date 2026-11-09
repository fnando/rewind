# frozen_string_literal: true

require "httpx"
require "securerandom"

module Rewind
  module Services
    # Read/auth client for a Jellyfin instance.
    #
    # - `public_users` (unauthenticated) suggests users when linking an account.
    # - `authenticate` exchanges username/password for a per-user access token.
    # - `rewind_changes` pages through the Rewind plugin's play history feed.
    # - `library_item` and friends read item metadata for the resolver.
    class Jellyfin
      Error = Class.new(Rewind::Error)
      AuthError = Class.new(Error)
      PluginMissing = Class.new(Error)

      # The Rewind Jellyfin plugin's id, as reported by /Rewind/Info.
      PLUGIN_ID = "6bcfddb4-c3fb-48f6-996f-5b02d07e3e62"
      PLUGIN_URL = "https://github.com/fnando/jellyfin-rewind-plugin"

      TIMEOUT = 8
      CHANGES_LIMIT = 1000
      ITEM_FIELDS = "ProviderIds,ParentIndexNumber,IndexNumber,SeriesId," \
                    "ParentId,DateCreated,PremiereDate,ProductionYear,Genres," \
                    "Path,Artists,AlbumArtists,Etag"

      def self.public_users(url)
        new(url).public_users
      end

      def initialize(url, token: nil, device_id: nil)
        @url = self.class.normalize_url(url)
        @token = token
        # A per-source device id keeps tokens from clobbering each other.
        # Default to a random one (not a shared constant) so we can never emit a
        # colliding device id even if a caller forgets to pass one.
        @device_id = device_id || SecureRandom.hex(16)
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
          user_name: data.dig("User", "Name"), server_id: data["ServerId"]
        }
      end

      # The username the token signs in as, or nil when it can't be read.
      def current_user_name
        name = JSON.parse(get("#{@url}/Users/Me").body.to_s)["Name"].to_s.strip
        name.empty? ? nil : name
      rescue Error, JSON::ParserError
        nil
      end

      # The server's own id (the ServerId every payload carries), from its
      # unauthenticated public info. nil when unreachable.
      def server_id
        response = http.get("#{@url}/System/Info/Public")
        return if response.is_a?(HTTPX::ErrorResponse)
        return unless response.status.between?(200, 299)

        id = JSON.parse(response.body.to_s)["Id"].to_s.strip
        id.empty? ? nil : id
      rescue JSON::ParserError
        nil
      end

      # The Rewind plugin's public info ({"id", "name", "repositoryUrl",
      # "version"}), to confirm a server has the plugin before an account is
      # linked. No sign-in needed. Raises PluginMissing when the server doesn't
      # have it (404, or a body that isn't the plugin's), Error on any other
      # failure.
      def rewind_info
        response = http.get("#{@url}/Rewind/Info")
        if not_found?(response)
          raise PluginMissing,
                "Rewind plugin not installed on this Jellyfin server " \
                "(/Rewind/Info: 404)"
        end

        body = check!(response).body.to_s
        info = JSON.parse(body)
        return info if info.is_a?(Hash) && plugin_id?(info["id"])

        raise PluginMissing,
              "/Rewind/Info isn't the Rewind plugin: #{body[0, 200]}"
      rescue JSON::ParserError
        raise PluginMissing,
              "/Rewind/Info isn't the Rewind plugin: #{body.to_s[0, 200]}"
      end

      # Jellyfin writes GUIDs without dashes ("N" format), so compare the
      # bare hex, whatever the format.
      private def plugin_id?(value)
        normalize = ->(id) { id.to_s.delete("-").downcase }
        normalize.call(value) == normalize.call(PLUGIN_ID)
      end

      # One page of the Rewind plugin's changes feed for the token's user:
      # every play created or changed after `since` (a sequence number), in
      # change order. Returns {"items" => [...], "nextSince" => Integer,
      # "hasMore" => bool}. Raises PluginMissing when the server doesn't have
      # the plugin (the route 404s).
      def rewind_changes(since:, limit: CHANGES_LIMIT)
        response = http(auth: token_auth_header).get(
          "#{@url}/Rewind/History/Changes",
          params: {since: since.to_i, limit: limit}
        )
        if not_found?(response)
          raise PluginMissing,
                "Rewind plugin not installed on this Jellyfin server"
        end

        page = JSON.parse(check!(response).body.to_s)
        # A page that isn't the feed's shape must fail loudly: read as "no
        # changes", it would silently import nothing.
        unless page.is_a?(Hash) && page["items"].is_a?(Array) &&
               page.key?("nextSince")
          raise Error, "Unexpected Rewind changes response: " \
                       "#{response.body.to_s[0, 200]}"
        end

        page
      rescue JSON::ParserError
        raise Error, "Rewind changes response isn't JSON"
      end

      # A single library item with every field the resolver reads. nil when the
      # server no longer has it (404); raises Error on any other failure, so a
      # transient outage is never mistaken for a deleted item.
      def library_item(user_id:, item_id:)
        response = http(auth: token_auth_header).get(
          "#{@url}/Users/#{user_id}/Items/#{item_id}",
          params: {Fields: ITEM_FIELDS}
        )
        return if not_found?(response)

        JSON.parse(check!(response).body.to_s)
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

      private def get(url, params = {})
        check!(http(auth: token_auth_header).get(url, params: params))
      end

      # The response when it succeeded; raises AuthError on 401, Error on any
      # other failure (transport error or non-2xx status).
      private def check!(response)
        if response.is_a?(HTTPX::ErrorResponse) ||
           !response.status.between?(200, 299)
          status = response.respond_to?(:status) ? response.status : "error"
          raise AuthError, "Jellyfin request unauthorized" if status == 401

          raise Error, "Jellyfin request failed: #{status}"
        end

        response
      end

      private def not_found?(response)
        !response.is_a?(HTTPX::ErrorResponse) && response.status == 404
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
