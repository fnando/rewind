# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    get "/settings" do
      @instances = Webhook.where(type: "jellyfin", enabled: true)
                          .order(:url).all
      @integrations = current_user.integrations_dataset
                                  .eager(:webhook).order(:created_at).all
      erb :"settings/index"
    end

    # Lazily fetched by the add-integration form once a username is typed, so a
    # page load never blocks on a (possibly unreachable) Jellyfin instance.
    get "/settings/jellyfin-users" do
      webhook = Webhook.where(id: params[:webhook_id].to_i, type: "jellyfin",
                              enabled: true).first
      halt 404 unless webhook

      content_type :json
      Services::Jellyfin.public_users(webhook.url).to_json
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

    post "/settings/integrations" do
      webhook = Webhook.where(id: params[:webhook_id].to_i, enabled: true).first
      unless webhook
        session[:flash_error] = "Pick a Jellyfin server to connect."
        redirect "/settings"
      end

      external_user_id = params[:external_user_id].to_s.strip
      if Integration.where(webhook_id: webhook.id,
                           external_user_id:).any?
        session[:flash_error] = "That Jellyfin user is already linked."
        redirect "/settings"
      end

      integration = Integration.new(
        user_id: current_user.id,
        webhook_id: webhook.id,
        external_user_id: external_user_id.empty? ? nil : external_user_id
      )

      unless integration.valid?
        session[:flash_error] = integration.errors.full_messages.join(". ")
        redirect "/settings"
      end

      integration.save
      redirect "/settings"
    end

    post "/settings/integrations/:id/toggle" do
      integration = current_user.integrations_dataset
                                .where(id: params[:id].to_i).first
      halt 404 unless integration
      integration.update(disabled_at: integration.disabled? ? nil : Time.now)
      redirect "/settings"
    end

    delete "/settings/integrations/:id" do
      integration = current_user.integrations_dataset
                                .where(id: params[:id].to_i).first
      halt 404 unless integration
      integration.destroy
      redirect "/settings"
    end
  end
end
