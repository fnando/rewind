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
    set :show_exceptions, false
    set :raise_errors, false
    set :dump_errors, false

    use ImageStore

    use Rack::Session::Cookie,
        key: "rewind.session",
        secret: Rewind.config.resolved_session_secret,
        same_site: :lax,
        secure: ENV["RACK_ENV"] == "production",
        httponly: true,
        expire_after: 60 * 60 * 24 * 30

    unless ENV["RACK_ENV"] == "test"
      use Rack::Protection,
          use: %i[
            authenticity_token form_token json_csrf remote_referrer
            http_origin
          ],
          except: %i[session_hijacking],
          allow_empty_referrer: true
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
      public_paths = ["/login", "/logout"]
      next if public_paths.include?(path)
      next if path.start_with?("/assets", "/public", "/images")

      halt redirect "/login" unless @current_user
    end

    before do
      next unless @current_user&.must_change_password

      allowed = %w[/logout /settings/password]
      next if allowed.include?(request.path_info)

      halt redirect "/settings/password"
    end

    error do
      e = env["sinatra.error"]
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
    require_relative "routes/items"
    require_relative "routes/history"
    require_relative "routes/images"
    require_relative "routes/settings"
    require_relative "routes/stats"
  end
end
