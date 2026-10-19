# frozen_string_literal: true

require "securerandom"

module Rewind
  class Application < Sinatra::Base
    get "/settings" do
      @sources = current_user.sources_dataset.order(:created_at).all
      @show_previous_error = params[:show_previous_error] == "true"
      erb :"settings/index"
    end

    post "/settings/rating-style" do
      style = params[:rating_style]
      if User::RATING_STYLES.include?(style)
        current_user.update(rating_style: style)
      end
      redirect "/settings"
    end

    post "/settings/avatar" do
      begin
        Services::Avatar.write(current_user, params[:avatar])
      rescue Services::Avatar::Error => error
        session[:flash_error] = error.message
      end
      redirect "/settings"
    end

    post "/settings/avatar/delete" do
      Services::Avatar.delete(current_user)
      redirect "/settings"
    end

    get "/avatars/:user_id" do
      user = User[params[:user_id].to_i]
      halt 404 unless user

      path = Services::Avatar.path_for(user)
      halt 404 unless path

      cache_control :public, max_age: 86_400
      content_type "image/jpeg"
      send_file(path)
    end

    post "/settings/timezone" do
      tz = params[:timezone].to_s
      if TZInfo::Timezone.all_identifiers.include?(tz)
        current_user.update(timezone: tz)
      end
      redirect "/settings"
    end

    get "/settings/password" do
      erb :"settings/password"
    end

    post "/settings/password" do
      current = params[:current_password].to_s
      new_password = params[:new_password].to_s
      confirmation = params[:password_confirmation].to_s

      unless current_user.must_change_password ||
             current_user.authenticate(current)
        @error = "Current password is incorrect."
        return erb(:"settings/password")
      end

      if new_password.length < 12
        @error = "New password must be at least 12 characters."
        return erb(:"settings/password")
      end

      if new_password != confirmation
        @error = "Passwords do not match."
        return erb(:"settings/password")
      end

      current_user.password = new_password
      current_user.must_change_password = false
      current_user.save
      redirect "/settings"
    end

    # Connect a Jellyfin account: sign in with username/password to get a
    # per-user access token (stored encrypted), then let the poller sync it.
    post "/settings/sources" do
      url = params[:url].to_s.strip
      username = params[:username].to_s.strip
      password = params[:password].to_s

      # On failure, re-render settings with the form open and the entered URL
      # and username prefilled, so nothing has to be retyped. The detail (with
      # the underlying reason) is logged at info level, so `rewind run
      # --verbose` surfaces it on the console.
      fail_form = lambda do |message, detail: nil|
        Rewind.logger.info(
          "[settings] jellyfin connection failed for " \
          "#{username.inspect} at #{url.inspect}: #{detail || message}"
        )
        session[:flash_error] = message
        @open_source_form = true
        @source_values = {url:, username:}
        @sources = current_user.sources_dataset.order(:created_at).all
        halt erb(:"settings/index")
      end

      if url.empty? || username.empty?
        fail_form.call("Enter your Jellyfin URL and username.")
      end

      # A random device id per source so Jellyfin binds this connection's token
      # to its own device, never clobbering another account's or environment's.
      device_id = SecureRandom.hex(16)

      begin
        auth = Services::Jellyfin.new(url, device_id:).authenticate(
          username:, password:
        )
      rescue Services::Jellyfin::AuthError, Services::Jellyfin::Error => error
        fail_form.call(
          "Could not sign in to Jellyfin. Check the URL and credentials.",
          detail: "#{error.class}: #{error.message}"
        )
      end

      source = Source.new(
        user_id: current_user.id, type: "jellyfin", url:, device_id:,
        external_user_id: auth[:user_id], instance_id: auth[:server_id]
      )
      source.credentials = {"access_token" => auth[:access_token]}

      begin
        if source.valid?
          source.save
        else
          fail_form.call(source.errors.full_messages.join(". "))
        end
      rescue Sequel::UniqueConstraintViolation
        fail_form.call("That Jellyfin account is already connected.")
      end

      redirect "/settings"
    end

    post "/settings/sources/:id/toggle" do
      source = current_user.sources_dataset.where(id: params[:id].to_i).first
      halt 404 unless source
      source.update(enabled: !source.enabled?)
      redirect "/settings"
    end

    delete "/settings/sources/:id" do
      source = current_user.sources_dataset.where(id: params[:id].to_i).first
      halt 404 unless source
      source.destroy
      redirect "/settings"
    end
  end
end
