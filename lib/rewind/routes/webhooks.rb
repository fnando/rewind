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
      halt 401, "unauthorized" unless webhook
      webhook.update(last_used_at: Time.now)

      payload =
        begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          halt 400, "invalid json"
        end

      Services::Webhooks::Jellyfin.record(payload)
      status 204
    end
  end
end
