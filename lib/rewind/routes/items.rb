# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    get "/search" do
      @query = params[:q].to_s.strip
      @results = []
      if !@query.empty? && Rewind.config.tmdb_api_key
        begin
          @results = Services::TMDB.new.search_multi(@query)
        rescue Services::TMDB::Error => error
          @error = error.message
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

      ui = UserItem.where(user_id: current_user.id,
                          item_key: item.rating_key).first
      if ui
        ui.update(rating: rating)
      else
        UserItem.create(user_id: current_user.id, item_key: item.rating_key,
                        rating: rating)
      end

      redirect(request.referer || "/items/#{item.id}")
    end

    post "/items/:id/review" do
      item = Item[params[:id].to_i]
      halt 404 unless item

      review = params[:review].to_s
      review = nil if review.strip.empty?
      ui = UserItem.where(user_id: current_user.id,
                          item_key: item.rating_key).first
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
        UserItem.create({
          user_id: current_user.id,
          item_key: item.rating_key
        }.merge(attrs))
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
        when "series"
          Services::TMDB.new.tv_item(tmdb_id)
        else
          halt 400, "Unsupported media_type"
        end

      redirect "/items/#{item.id}"
    end

    post "/items/:id/log-episode" do
      show = Item[params[:id].to_i]
      halt 404 unless show && show.media_type == "series"

      season = params[:season].to_i
      episode = params[:episode].to_i
      unless season.positive? && episode.positive?
        halt 400,
             "Invalid season/episode"
      end

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
      @user_item = UserItem.where(user_id: current_user.id,
                                  item_key: @item.rating_key).first

      case @item.media_type
      when "episode"
        @plays = Play.where(user_id: current_user.id, item_id: @item.id)
                     .order(Sequel.desc(:played_at))
                     .all
        @show = Item.where(media_type: "series",
                           external_id: @item.parent_external_id).first
        erb :"items/show_episode"
      when "series"
        # Jellyfin-native series (e.g. YouTube channels) have no TMDB seasons;
        # list the actual episodes we've recorded instead of faking a season.
        if @item.metadata["source"] == "jellyfin"
          @generic_series = true
          @episode_plays = Play.where(user_id: current_user.id)
                               .join(:items, id: :item_id)
                               .where(
                                 Sequel[:items][:media_type] => "episode",
                                 Sequel[:items][:parent_external_id] =>
                                   @item.external_id
                               )
                               .select_all(:plays)
                               .order(Sequel.desc(Sequel[:plays][:played_at]))
                               .eager(:item)
                               .all
          @plays_by_episode_item = @episode_plays.group_by(&:item_id)
          @episodes = @episode_plays.map(&:item).uniq(&:id)
          @user_items_by_item = load_user_items_for(@episode_plays)
          halt erb(:"items/show_series_generic")
        end

        seasons = Array(@item.metadata["seasons"]).reject do |s|
          s["season_number"].to_i.zero?
        end
        if seasons.empty?
          seasons = [
            {
              "season_number" => 1,
              "episode_count" => 10
            }
          ]
        end
        @seasons = seasons
        @current_season =
          (params[:season] || seasons.first["season_number"]).to_i
        current = seasons.find do |s|
          s["season_number"] == @current_season
        end || seasons.first
        @episode_count = current["episode_count"].to_i

        @episode_plays = Play.where(user_id: current_user.id)
                             .join(:items, id: :item_id)
                             .where(
                               Sequel[:items][:media_type] => "episode",
                               Sequel[:items][:parent_external_id] =>
                                 @item.external_id,
                               Sequel[:items][:season_number] => @current_season
                             )
                             .select_all(:plays)
                             .order(Sequel.desc(Sequel[:plays][:played_at]))
                             .eager(:item)
                             .all

        @plays_by_episode = @episode_plays.group_by {|p| p.item.episode_number }

        @user_items_by_episode = {}
        episodes = @episode_plays.map(&:item).uniq(&:id)
        by_key = episodes.each_with_object({}) {|e, h| h[e.rating_key] = e }
        unless by_key.empty?
          UserItem.where(user_id: current_user.id,
                         item_key: by_key.keys).each do |ui|
            episode = by_key[ui.item_key]
            @user_items_by_episode[episode.episode_number] = ui if episode
          end
        end

        @season_episodes =
          if Rewind.config.tmdb_api_key
            begin
              Array(Services::TMDB.new.season(@item.tmdb_id,
                                              @current_season)["episodes"])
                .each_with_object({}) do |e, h|
                h[e["episode_number"]] = e
              end
            rescue Services::TMDB::Error
              {}
            end
          else
            {}
          end
        @all_episode_plays_count =
          Play.where(user_id: current_user.id)
              .join(:items, id: :item_id)
              .where(
                Sequel[:items][:media_type] => "episode",
                Sequel[:items][:parent_external_id] => @item.external_id
              )
              .select(Sequel[:plays][:item_id])
              .distinct
              .count
        @total_episodes = seasons.sum {|s| s["episode_count"].to_i }
        erb :"items/show_series"
      when "track"
        @plays = Play.where(user_id: current_user.id, item_id: @item.id)
                     .order(Sequel.desc(:played_at))
                     .all
        @album = Item.where(
          external_id: @item.metadata["album_external_id"]
        ).first
        @artist = Item.where(
          external_id: @item.metadata["artist_external_id"]
        ).first
        erb :"items/show_track"
      when "album"
        @artist = Item.where(external_id: @item.parent_external_id).first
        @tracks = Item.where(media_type: "track",
                             parent_external_id: @item.external_id).all
        @tracks.sort_by! do |t|
          [t.disc_number || 0, t.track_number || 0, t.title.to_s]
        end
        track_ids = @tracks.map(&:id)
        @play_counts =
          if track_ids.empty?
            {}
          else
            Play.where(user_id: current_user.id, item_id: track_ids)
                .group_and_count(:item_id).to_hash(:item_id, :count)
          end
        counts = @tracks.map {|t| @play_counts[t.id].to_i }
        @total_plays = counts.sum
        @max_track_plays = counts.max.to_i
        # A lower bound on full listens: times every track has been heard.
        @complete_listens = counts.min.to_i
        @total_length_ms = @tracks.sum {|t| t.metadata["length_ms"].to_i }
        @last_played =
          unless track_ids.empty?
            Play.where(user_id: current_user.id, item_id: track_ids)
                .exclude(played_at: nil)
                .order(Sequel.desc(:played_at)).first&.played_at
          end
        erb :"items/show_album"
      when "artist"
        @albums = Item.where(media_type: "album",
                             parent_external_id: @item.external_id)
                      .order(:title).all
        @user_items_by_item = user_items_by_item_id(@albums)
        erb :"items/show_artist"
      else
        @plays = Play.where(user_id: current_user.id, item_id: @item.id)
                     .order(Sequel.desc(:played_at))
                     .all
        erb :"items/show"
      end
    end
  end
end
