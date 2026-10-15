# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    post "/webhooks/:kind/:token" do
      kind = params[:kind]
      halt 404 unless Integration::KINDS.include?(kind)

      integration = Integration.where(
        kind: kind,
        token_digest: Integration.digest_token(params[:token])
      ).first
      halt 404 unless integration
      halt 403 if integration.disabled?

      payload = parse_webhook_body
      halt 400, "invalid payload" unless payload

      handler =
        case kind
        when "jellyfin" then Services::Webhooks::Jellyfin
        end

      result = handler.call(integration: integration, payload: payload, headers: request.env)
      integration.update(last_event_at: Time.now)

      case result
      when Play
        Rewind.logger.info("[webhook/#{kind}] recorded play #{result.id} (item=#{result.item_id})")
        status 201
        content_type :json
        {status: "recorded", play_id: result.id}.to_json
      when Symbol
        Rewind.logger.info("[webhook/#{kind}] skipped: #{result} payload=#{payload.to_json}")
        status 204
      else
        status 204
      end
    rescue Services::Webhooks::Jellyfin::Error, Services::TMDB::Error => e
      Rewind.logger.warn("[webhook/#{params[:kind]}] #{e.message}")
      status 422
      content_type :json
      {error: e.message}.to_json
    end

    private

    def parse_webhook_body
      body = request.body.read
      return nil if body.nil? || body.empty?

      case request.media_type
      when "application/json", nil, ""
        JSON.parse(body)
      when "application/x-www-form-urlencoded"
        parsed = Rack::Utils.parse_nested_query(body)
        if parsed.key?("payload")
          JSON.parse(parsed["payload"])
        else
          parsed
        end
      else
        JSON.parse(body)
      end
    rescue JSON::ParserError
      nil
    end
  end
end
