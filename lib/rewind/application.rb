# frozen_string_literal: true

require "sinatra/base"
require "sinatra/contrib"
require "rack/protection"
require "erubi"

# Domain code (models + services) comes from the central boot; here we add only
# the web layer on top of it.
require_relative "boot"
require_relative "helpers/view_helper"
require_relative "helpers/rating_helper"
require_relative "presenters/play_card"
require_relative "image_store"

module Rewind
  class Application < Sinatra::Base
    set :root, Rewind.root
    set :host_authorization, permitted_hosts: Rewind.config.allowed_hosts
    set :views, Rewind.config.views_dir
    set :public_folder, Rewind.config.public_dir
    set :static, true
    set :method_override, true
    set :erb, escape_html: false
    set :sessions, false
    set :show_exceptions, development?
    set :raise_errors, development?
    set :dump_errors, development?
    set :logging, development?

    use ImageStore

    use Rack::Session::Cookie,
        key: "rewind.session",
        secret: Rewind.config.resolved_session_secret,
        same_site: :lax,
        secure: production?,
        httponly: true,
        expire_after: 60 * 60 * 24 * 30

    unless test?
      use Rack::Protection,
          use: %i[
            authenticity_token form_token json_csrf remote_referrer
            http_origin
          ],
          except: %i[session_hijacking],
          allow_empty_referrer: true,
          # Inbound webhooks are machine-to-machine and authenticate by secret,
          # not a session/CSRF token, so skip the browser protections for them.
          allow_if: ->(env) { env["PATH_INFO"].to_s.start_with?("/webhooks/") }
    end

    helpers Helpers::ViewHelper
    helpers Helpers::RatingHelper

    before do
      @current_user =
        (User.where(id: session[:user_id]).first if session[:user_id])
      session.delete(:user_id) if session[:user_id] && @current_user.nil?
    end

    before do
      path = request.path_info
      public_paths = ["/login", "/logout", "/info"]
      next if public_paths.include?(path)
      next if path.start_with?("/assets", "/public", "/images", "/webhooks")

      halt redirect "/login" unless @current_user
    end

    before do
      next unless @current_user&.must_change_password

      allowed = %w[/logout /settings/password]
      next if allowed.include?(request.path_info)

      halt redirect "/settings/password"
    end

    # Capturing the request's data that caused an error, with secrets stripped,
    # so the admin error page can show what was happening when it broke.
    helpers do
      def error_context
        {
          "method" => request.request_method,
          "path" => request.fullpath,
          "params" => sanitized_params,
          "user_id" => @current_user&.id,
          "ip" => request.ip,
          "user_agent" => request.user_agent
        }
      rescue StandardError
        {}
      end

      def sanitized_params
        params.reject {|key, _| key.to_s.match?(/password|secret|token/i) }
      rescue StandardError
        {}
      end
    end

    error do
      e = env["sinatra.error"]
      ErrorLog.record(e, context: error_context)
      backtrace = e.backtrace&.first(10)&.join("\n")
      Rewind.logger.error("#{e.class}: #{e.message}\n#{backtrace}")
      status 500
      erb :"errors/500", layout: :layout
    end

    not_found do
      status 404
      erb :"errors/404", layout: :layout
    end

    require_relative "routes/auth"
    require_relative "routes/info"
    require_relative "routes/webhooks"
    require_relative "routes/items"
    require_relative "routes/history"
    require_relative "routes/images"
    require_relative "routes/settings"
    require_relative "routes/errors"
    require_relative "routes/stats"
  end
end
