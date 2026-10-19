# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    # Unauthenticated JSON health/version endpoint: `curl http://host/info`.
    get "/info" do
      content_type :json
      JSON.generate(
        version: Rewind::VERSION,
        environment: settings.environment.to_s,
        tzdata_version:
      )
    end
  end
end
