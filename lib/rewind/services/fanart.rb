# frozen_string_literal: true

require "httpx"

module Rewind
  module Services
    # Artist photos from fanart.tv, looked up directly by MusicBrainz artist id.
    class Fanart
      Error = Class.new(Rewind::Error)
      BASE_URL = "https://webservice.fanart.tv/v3.2"

      def initialize(api_key: Rewind.config.fanart_api_key)
        @api_key = api_key
      end

      # Returns an image URL or nil. Never raises: a missing key, a synthetic
      # (keyless) artist, a 404, or any transport error all mean "no photo" so
      # that ingestion is never blocked on artwork.
      def artist_image(mbid)
        return if @api_key.to_s.empty?
        return if mbid.to_s.empty?

        data = get("/music/#{mbid}")
        images = Array(data["artistthumb"]) + Array(data["artistbackground"])
        images.filter_map {|image| image["url"] }.first
      rescue Error
        nil
      end

      private def get(path)
        response = HTTPX.get("#{BASE_URL}#{path}",
                             params: {api_key: @api_key})

        unless response.status.between?(200, 299)
          raise Error, "fanart.tv request failed: #{response.status}"
        end

        JSON.parse(response.body.to_s)
      end
    end
  end
end
