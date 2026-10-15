# frozen_string_literal: true

require "date"

module Rewind
  module Services
    class Stats
      def self.resolve_period(period, from = nil, to = nil)
        now = Time.now
        today = Date.today
        case period
        when "week"
          start = today - 6
          [Time.new(start.year, start.month, start.day), now]
        when "month"
          start = today - 29
          [Time.new(start.year, start.month, start.day), now]
        when "all"
          [nil, nil]
        when "custom"
          from_t = parse_time(from) || (now - (365 * 86_400))
          to_t = parse_time(to) || now
          [from_t, to_t]
        else # year
          start = Date.new(today.year, 1, 1)
          [Time.new(start.year, start.month, start.day), now]
        end
      end

      def self.parse_time(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def initialize(user:, media_type: "all", from: nil, to: nil)
        @user = user
        @media_type = media_type
        @from = from
        @to = to
      end

      def to_h
        plays = load_plays

        {
          totals: compute_totals(plays),
          by_genre: compute_by_genre(plays),
          by_period: compute_by_period(plays),
          top_items: compute_top_items(plays),
          top_people: compute_top_people(plays),
          period: {from: @from, to: @to}
        }
      end

      private

      def load_plays
        scope = Play.for_user(@user)
          .in_period(@from, @to)
          .eager(:item)
          .order(:played_at)

        scope = scope.for_media_type("movie") if @media_type == "movie"
        scope = scope.for_media_type("episode") if @media_type == "tv"
        scope.all
      end

      def compute_totals(plays)
        unique_keys = plays.map {|p| p.item.media_type == "episode" ? [:show, p.item.parent_tmdb_id] : [:movie, p.item.tmdb_id] }.uniq
        hours = plays.sum {|p| (p.item.runtime || 0).to_i } / 60.0

        pair_counts = Hash.new(0)
        plays.each {|p| pair_counts[[p.user_id, p.item_id]] += 1 }
        rewatches = pair_counts.values.sum {|c| c > 1 ? c - 1 : 0 }

        {
          plays: plays.size,
          unique_titles: unique_keys.size,
          hours_watched: hours.round(1),
          rewatches: rewatches
        }
      end

      def compute_by_genre(plays)
        counts = Hash.new(0)
        plays.each do |play|
          genres = play.item.genres
          genres.each {|g| counts[g] += 1 }
        end
        sorted = counts.sort_by {|_, c| -c }
        top = sorted.first(15)
        others = sorted.drop(15)
        top << ["Other", others.sum {|_, c| c }] if others.any?
        top
      end

      def compute_by_period(plays)
        return [] if plays.empty?

        bucket_fn, label_fn = pick_bucketing(plays)
        counts = Hash.new(0)
        plays.each do |play|
          counts[bucket_fn.call(play.played_at)] += 1
        end
        counts.sort_by {|k, _| k }.map {|k, c| [label_fn.call(k), c] }
      end

      def pick_bucketing(plays)
        span_days = ((plays.last.played_at - plays.first.played_at) / 86_400.0).ceil
        if span_days <= 10
          [->(t) { t.to_date }, ->(d) { d.strftime("%a %b %-d") }]
        elsif span_days <= 90
          [->(t) { t.to_date }, ->(d) { d.strftime("%b %-d") }]
        elsif span_days <= 400
          [->(t) { [t.year, t.month] }, ->(k) { Date.new(k[0], k[1], 1).strftime("%b %Y") }]
        else
          [->(t) { t.year }, ->(y) { y.to_s }]
        end
      end

      def compute_top_items(plays)
        {movies: top_by_item(plays, "movie"), shows: top_shows(plays)}
      end

      def top_by_item(plays, media_type)
        scoped = plays.select {|p| p.item.media_type == media_type }
        counts = Hash.new(0)
        items = {}
        scoped.each do |p|
          counts[p.item_id] += 1
          items[p.item_id] = p.item
        end
        counts.sort_by {|_, c| -c }.first(10).map {|id, c| [items[id], c] }
      end

      def top_shows(plays)
        episode_plays = plays.select {|p| p.item.media_type == "episode" }
        counts = Hash.new(0)
        names = {}
        episode_plays.each do |p|
          key = p.item.parent_tmdb_id
          counts[key] += 1
          names[key] ||= p.item.metadata["series_name"] || "Show #{key}"
        end
        counts.sort_by {|_, c| -c }.first(10).map {|k, c| [names[k], c] }
      end

      def compute_top_people(plays)
        directors = Hash.new(0)
        cast = Hash.new(0)
        plays.each do |play|
          credits = play.item.credits
          Array(credits["crew"]).each do |crew|
            if %w[Director Creator].include?(crew["job"])
              directors[crew["name"]] += 1
            end
          end
          Array(credits["cast"]).first(10).each do |actor|
            cast[actor["name"]] += 1
          end
        end
        {
          directors: directors.sort_by {|_, c| -c }.first(10),
          cast: cast.sort_by {|_, c| -c }.first(10)
        }
      end
    end
  end
end
