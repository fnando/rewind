# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    get "/login" do
      redirect "/" if current_user
      @no_users = User.count.zero?
      erb :"auth/login"
    end

    post "/login" do
      user = User.where(username: params[:username].to_s.strip).first
      if user && user.authenticate(params[:password].to_s)
        session[:user_id] = user.id
        user.update(last_login_at: Time.now)
        redirect "/"
      else
        @no_users = User.count.zero?
        @error = "Invalid username or password."
        status 401
        erb :"auth/login"
      end
    end

    post "/logout" do
      session.clear
      redirect "/login"
    end
  end
end
