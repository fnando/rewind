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
                  "PremiereDate,ProductionYear,Genres",
          Limit: 500
        )
        Array(JSON.parse(response.body.to_s)["Items"])
      rescue Error
        []
      end

      private def get_items(user_id, start_index)
        response = get(
          "#{@url}/Users/#{user_id}/Items",
          IncludeItemTypes: PLAYED_TYPES,
          Recursive: true,
          Filters: "IsPlayed",
          SortBy: "DatePlayed",
          SortOrder: "Descending",
          Fields: "ProviderIds,ParentIndexNumber,IndexNumber,SeriesId," \
                  "ParentId,DateCreated,PremiereDate,ProductionYear,Genres",
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
    end
  end
end
