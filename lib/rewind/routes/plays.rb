# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    get "/" do
      redirect "/plays"
    end

    get "/plays" do
      @type = params[:type]
      scope = Play.for_user(current_user).order(Sequel.desc(:played_at)).eager(:item)
      scope = scope.for_media_type(@type) if @type && @type != "all"
      @plays = scope.limit(200).all
      tz = TZInfo::Timezone.get(current_user.timezone || "UTC")
      @plays_by_day = @plays.group_by {|p| tz.to_local(p.played_at.utc).to_date }
      @user_items_by_item = load_user_items_for(@plays)
      @shows_by_tmdb = load_shows_for(@plays)
      erb :"plays/index"
    end

    post "/plays" do
      item_id = params[:item_id].to_i
      item = Item[item_id]
      halt 404 unless item

      played_at =
        begin
          params[:played_at] && !params[:played_at].empty? ? Time.parse(params[:played_at]) : Time.now
        rescue ArgumentError
          Time.now
        end

      Play.create(
        user_id: current_user.id,
        item_id: item.id,
        played_at: played_at,
        source: "manual"
      )

      redirect "/items/#{item.id}"
    end

    delete "/plays/:id" do
      play = Play.where(id: params[:id].to_i, user_id: current_user.id).first
      halt 404 unless play

      play.destroy
      redirect(request.referer || "/plays")
    end
  end
end
