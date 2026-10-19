# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    PLAYS_PER_PAGE = 200

    get "/" do
      redirect "/history"
    end

    get "/history" do
      @type = params[:type]
      @page = [params[:page].to_i, 1].max
      scope = Play.for_user(current_user)
                  .order(Sequel.desc(:played_at))
                  .eager(:item)
      scope = scope.for_media_type(@type) if @type && @type != "all"
      rows = scope.limit(PLAYS_PER_PAGE + 1)
                  .offset((@page - 1) * PLAYS_PER_PAGE).all
      @has_prev = @page > 1
      @has_next = rows.size > PLAYS_PER_PAGE
      @plays = rows.first(PLAYS_PER_PAGE)
      tz = TZInfo::Timezone.get(current_user.timezone || "UTC")
      @plays_by_day = @plays.group_by do |p|
        p.played_at ? tz.to_local(p.played_at.utc).to_date : nil
      end
      @shows_by_tmdb = load_shows_for(@plays)
      @music_parents = load_music_parents_for(@plays)
      album_items = @music_parents.values.select {|i| i.media_type == "album" }
      @user_items_by_item = load_user_items_for(@plays)
                            .merge(user_items_by_item_id(album_items))
      erb :"history/index"
    end

    post "/history" do
      item_id = params[:item_id].to_i
      item = Item[item_id]
      halt 404 unless item
      # Music is only ever recorded from scrobbles, never logged by hand.
      halt 422, "Tracks can't be logged manually" if item.media_type == "track"

      played_at =
        begin
          if params[:played_at] && !params[:played_at].empty?
            Time.parse(params[:played_at])
          else
            Time.now
          end
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

    delete "/history/:id" do
      play = Play.where(id: params[:id].to_i, user_id: current_user.id).first
      halt 404 unless play

      play.destroy
      redirect(request.referer || "/history")
    end
  end
end
