# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    get "/search" do
      @query = params[:q].to_s.strip
      @results = []
      if !@query.empty? && Rewind.config.tmdb_api_key
        begin
          @results = Services::TMDB.new.search_multi(@query)
        rescue Services::TMDB::Error => e
          @error = e.message
        end
      end
      erb :"items/search"
    end

    post "/items/:id/rating" do
      item = Item[params[:id].to_i]
      halt 404 unless item

      raw = params[:rating].to_s
      rating =
        case raw
        when "", "clear" then nil
        when "up" then 5
        when "down" then 1
        else
          value = raw.to_i
          (1..5).cover?(value) ? value : nil
        end

      ui = UserItem.where(user_id: current_user.id, item_id: item.id).first
      if ui
        ui.update(rating: rating)
      else
        UserItem.create(user_id: current_user.id, item_id: item.id, rating: rating)
      end

      redirect(request.referer || "/items/#{item.id}")
    end

    post "/items/:id/review" do
      item = Item[params[:id].to_i]
      halt 404 unless item

      review = params[:review].to_s
      review = nil if review.strip.empty?
      ui = UserItem.where(user_id: current_user.id, item_id: item.id).first
      now = Time.now

      attrs = {review: review}
      if review.nil?
        attrs[:review_created_at] = nil
        attrs[:review_updated_at] = nil
      elsif ui.nil? || ui.review.to_s != review
        attrs[:review_created_at] = ui&.review_created_at || now
        attrs[:review_updated_at] = now
      end

      if ui
        ui.update(attrs)
      else
        UserItem.create({user_id: current_user.id, item_id: item.id}.merge(attrs))
      end

      redirect("/items/#{item.id}")
    end

    post "/items/import" do
      type = params[:media_type]
      tmdb_id = params[:tmdb_id].to_i

      item =
        case type
        when "movie"
          Services::TMDB.new.movie(tmdb_id)
        when "tv"
          Services::TMDB.new.tv_item(tmdb_id)
        else
          halt 400, "Unsupported media_type"
        end

      redirect "/items/#{item.id}"
    end

    post "/items/:id/log-episode" do
      show = Item[params[:id].to_i]
      halt 404 unless show && show.media_type == "tv"

      season = params[:season].to_i
      episode = params[:episode].to_i
      halt 400, "Invalid season/episode" unless season.positive? && episode.positive?

      item = Services::TMDB.new.episode(show.tmdb_id, season, episode)
      Play.create(
        user_id: current_user.id,
        item_id: item.id,
        played_at: Time.now,
        source: "manual"
      )

      redirect "/items/#{show.id}"
    end

    get "/items/:id" do
      @item = Item[params[:id].to_i]
      halt 404 unless @item
      @user_item = UserItem.where(user_id: current_user.id, item_id: @item.id).first

      if @item.media_type == "episode"
        @plays = Play.where(user_id: current_user.id, item_id: @item.id)
          .order(Sequel.desc(:played_at))
          .all
        @show = Item.where(media_type: "tv", tmdb_id: @item.parent_tmdb_id).first
        erb :"items/show_episode"
      elsif @item.media_type == "tv"
        seasons = Array(@item.metadata["seasons"]).reject {|s| s["season_number"].to_i.zero? }
        seasons = [{"season_number" => 1, "episode_count" => 10}] if seasons.empty?
        @seasons = seasons
        @current_season = (params[:season] || seasons.first["season_number"]).to_i
        current = seasons.find {|s| s["season_number"] == @current_season } || seasons.first
        @episode_count = current["episode_count"].to_i

        @episode_plays = Play.where(user_id: current_user.id)
          .join(:items, id: :item_id)
          .where(Sequel[:items][:media_type] => "episode",
                 Sequel[:items][:parent_tmdb_id] => @item.tmdb_id,
                 Sequel[:items][:season_number] => @current_season)
          .select_all(:plays)
          .order(Sequel.desc(Sequel[:plays][:played_at]))
          .eager(:item)
          .all

        @plays_by_episode = @episode_plays.group_by {|p| p.item.episode_number }

        @user_items_by_episode = {}
        episode_item_ids = @episode_plays.map(&:item_id).uniq
        unless episode_item_ids.empty?
          UserItem.where(user_id: current_user.id, item_id: episode_item_ids).each do |ui|
            item = @episode_plays.find {|p| p.item_id == ui.item_id }&.item
            @user_items_by_episode[item.episode_number] = ui if item
          end
        end

        @season_episodes =
          if Rewind.config.tmdb_api_key
            begin
              Array(Services::TMDB.new.season(@item.tmdb_id, @current_season)["episodes"])
                .each_with_object({}) {|e, h| h[e["episode_number"]] = e }
            rescue Services::TMDB::Error
              {}
            end
          else
            {}
          end
        @all_episode_plays_count = Play.where(user_id: current_user.id)
          .join(:items, id: :item_id)
          .where(Sequel[:items][:media_type] => "episode",
                 Sequel[:items][:parent_tmdb_id] => @item.tmdb_id)
          .select(Sequel[:plays][:item_id])
          .distinct
          .count
        @total_episodes = seasons.sum {|s| s["episode_count"].to_i }
        erb :"items/show_tv"
      else
        @plays = Play.where(user_id: current_user.id, item_id: @item.id)
          .order(Sequel.desc(:played_at))
          .all
        erb :"items/show"
      end
    end
  end
end
