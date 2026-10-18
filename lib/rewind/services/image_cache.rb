# frozen_string_literal: true

require "httpx"

module Rewind
  module Services
    # Fetches a remote cover image and returns its raw bytes, or nil on any
    # failure. Only well-known image hosts are allowed, and redirects are
    # followed (Cover Art Archive redirects to archive.org storage).
    module ImageCache
      ALLOWED_HOSTS = %w[
        image.tmdb.org coverartarchive.org assets.fanart.tv
      ].freeze
      TIMEOUT = 8
      MAX_BYTES = 5 * 1024 * 1024

      module_function def fetch(url)
        uri = URI.parse(url.to_s)
        return unless uri.is_a?(URI::HTTPS) && ALLOWED_HOSTS.include?(uri.host)

        response = client.get(url)
        return if response.is_a?(HTTPX::ErrorResponse)
        return unless response.status.between?(200, 299)

        body = response.body.to_s
        return if body.empty? || body.bytesize > MAX_BYTES

        body
      rescue StandardError => error
        Rewind.logger.info("[images] fetch failed for #{url}: #{error.message}")
        nil
      end

      module_function def client
        HTTPX
          .plugin(:follow_redirects)
          .with(timeout: {connect_timeout: TIMEOUT, operation_timeout: TIMEOUT})
      end
    end
  end
end
