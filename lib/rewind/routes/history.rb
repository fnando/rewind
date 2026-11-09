# frozen_string_literal: true

module Rewind
  class Application < Sinatra::Base
    DAYS_PER_PAGE = 2

    get "/" do
      redirect "/history"
    end

    get "/history" do
      @type = params[:type]
      @page = [params[:page].to_i, 1].max

      scope = Play.for_user(current_user).order(Sequel.desc(:played_at))
      if @type && @type != "all"
        # The "Music" nav uses type=track; widen it to also cover music videos.
        filter = @type == "track" ? Play::MUSIC_MEDIA_TYPES : @type
        scope = scope.for_media_type(filter)
      end

      # Paginate by day of activity, not a fixed row count: each page spans
      # DAYS_PER_PAGE days that had plays, however far apart they fall on the
      # calendar. Grouping reads each play's frozen local_date, so it's a single
      # indexed DISTINCT query — no per-row timezone math. Undated plays (null
      # local_date) sort last and form a single trailing "day".
      skip = (@page - 1) * DAYS_PER_PAGE
      recent_days = scope.exclude(local_date: nil)
                         .distinct
                         .order(Sequel.desc(:local_date))
                         .limit(DAYS_PER_PAGE + 1).offset(skip)
                         .select_map(:local_date)
      undated = scope.where(local_date: nil).get(1) ? true : false

      window = recent_days.first(DAYS_PER_PAGE)
      include_undated = window.size < DAYS_PER_PAGE && undated
      @has_prev = @page > 1
      # A full window of real days may still have the undated group after it.
      @has_next =
        if recent_days.size > DAYS_PER_PAGE then true
        elsif window.size == DAYS_PER_PAGE then undated
        else false
        end

      @plays = plays_for_days(scope.eager(:item), window, include_undated)
      @plays_by_day = @plays.group_by do |play|
        play.local_date ? Date.parse(play.local_date) : nil
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

      played_at = manual_played_at

      Play.create(
        user_id: current_user.id,
        item_id: item.id,
        played_at: played_at,
        source: "manual"
      )

      redirect "/items/#{item.id}"
    end

    helpers do
      # When a hand-logged watch happened: the `played_at` form value, a
      # wall-clock time in the user's timezone, as UTC. Blank means now. Halts
      # on a value that isn't a date/time, or one in the future.
      def manual_played_at
        raw = params[:played_at].to_s.strip
        return Time.now if raw.empty?

        played_at = current_user.local_time_to_utc(raw)
        halt 400, "Invalid date and time" unless played_at
        # A minute of slack: the form's default is "now", already past.
        halt 422, "A watch can't be in the future" if played_at > Time.now + 60

        played_at
      end
    end

    delete "/history/:id" do
      play = Play.where(id: params[:id].to_i, user_id: current_user.id).first
      halt 404 unless play

      play.destroy
      redirect(request.referer || "/history")
    end
  end
end
