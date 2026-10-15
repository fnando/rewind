# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    get "/settings" do
      @integrations = current_user.integrations_dataset.order(:created_at).all
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
      rescue Services::Avatar::Error => e
        session[:flash_error] = e.message
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

      unless current_user.must_change_password || current_user.authenticate(current)
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
      kind = params[:kind].to_s
      kind = "jellyfin" unless Integration::KINDS.include?(kind)

      instance_url = params[:instance_url].to_s.strip
      instance_url = nil if instance_url.empty?
      instance_url = instance_url.sub(%r{/+$}, "") if instance_url

      integration = Integration.new(
        user_id: current_user.id,
        kind: kind,
        label: params[:label].to_s.strip.empty? ? "#{kind.capitalize} server" : params[:label],
        instance_url: instance_url,
        external_user_id: params[:external_user_id].to_s.strip.empty? ? nil : params[:external_user_id].strip,
        token: Integration.generate_token
      )

      unless integration.valid?
        session[:flash_error] = integration.errors.full_messages.join(". ")
        redirect "/settings"
      end

      integration.save
      redirect "/settings"
    end

    post "/settings/integrations/:id/rotate" do
      integration = current_user.integrations_dataset.where(id: params[:id].to_i).first
      halt 404 unless integration
      integration.rotate_token!
      redirect "/settings"
    end

    post "/settings/integrations/:id/toggle" do
      integration = current_user.integrations_dataset.where(id: params[:id].to_i).first
      halt 404 unless integration
      integration.update(disabled_at: integration.disabled? ? nil : Time.now)
      redirect "/settings"
    end

    delete "/settings/integrations/:id" do
      integration = current_user.integrations_dataset.where(id: params[:id].to_i).first
      halt 404 unless integration
      integration.destroy
      redirect "/settings"
    end
  end
end
