# frozen_string_literal: true

require "httpx"

module Rewind
  module Services
    # Thin read-only client for a Jellyfin instance. Only talks to the
    # unauthenticated `/Users/Public` endpoint, used to suggest users when
    # linking an account. Any failure (unreachable, timeout, bad JSON) yields an
    # empty list — the picker is a convenience, never a hard dependency.
    class Jellyfin
      TIMEOUT = 4

      def self.public_users(url)
        new(url).public_users
      end

      def initialize(url)
        @url = url.to_s.strip.sub(%r{/+\z}, "")
      end

      def public_users
        return [] if @url.empty?

        response = HTTPX
                   .with(
                     # System resolver (getaddrinfo) so instance URLs resolve
                     # like the OS does — honouring mDNS and /etc/hosts.
                     resolver_class: :system,
                     timeout: {
                       connect_timeout: TIMEOUT, operation_timeout: TIMEOUT
                     },
                     headers: {"Accept" => "application/json"}
                   )
                   .get("#{@url}/Users/Public")
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
    end
  end
end
