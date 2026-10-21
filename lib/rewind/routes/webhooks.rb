# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    # Inbound playback webhooks. The secret in the path authenticates the
    # instance; the payload's UserId maps to the Rewind user. Always answers
    # 2xx once authenticated so Jellyfin doesn't retry an event we chose to
    # ignore. CSRF/session protection is bypassed for /webhooks (see the
    # Rack::Protection allow_if in application.rb) — the secret is the auth.
    post "/webhooks/jellyfin/:secret" do
      webhook = Webhook.authenticate(params[:secret])
      unless webhook
        Rewind.logger.warn("[webhook/jellyfin] rejected: unknown secret")
        halt 401, "unauthorized"
      end
      webhook.update(last_used_at: Time.now)

      body = request.body.read
      payload =
        begin
          JSON.parse(body)
        rescue JSON::ParserError
          # Log the body so a malformed Jellyfin webhook template is diagnosable
          # instead of silently 400ing. inspect keeps it one line and shows the
          # offending characters.
          Rewind.logger.warn(
            "[webhook/jellyfin] rejected: invalid json " \
            "(#{body.bytesize} bytes): #{body[0, 200].inspect}"
          )
          halt 400, "invalid json"
        end

      Services::Webhooks::Jellyfin.record(payload)
      status 204
    end
  end
end
