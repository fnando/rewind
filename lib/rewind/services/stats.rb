# frozen_string_literal: true

require "date"

module Rewind
  module Services
    class Stats
      MONTH_NAMES = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze
      FULL_MONTH_NAMES = Date::MONTHNAMES.compact.freeze

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

      def initialize(user:, media_type: "all", from: nil, to: nil, period: "year")
        @user = user
        @media_type = media_type
        @from = from
        @to = to
        @period = period
      end

      def to_h
        plays = load_plays

        {
          period: {from: @from, to: @to, kind: @period, label: period_label},
          totals: compute_totals(plays),
          headline: compute_headline(plays),
          cards: compute_cards(plays),
          rhythm: compute_rhythm(plays),
          heatmap: compute_heatmap(plays),
          top_genres: compute_by_genre(plays),
          top_shows: compute_top_shows(plays),
          top_movies: compute_top_movies(plays),
          top_cast: compute_top_cast(plays),
          top_directors: compute_top_directors(plays)
        }
      end

      private

      def user_tz
        TZInfo::Timezone.get(@user&.timezone || "UTC")
      rescue TZInfo::InvalidTimezoneIdentifier
        TZInfo::Timezone.get("UTC")
      end

      def load_plays
        scope = Play.for_user(@user)
          .in_period(@from, @to)
          .eager(:item)
          .order(:played_at)

        scope = scope.for_media_type("movie") if @media_type == "movie"
        scope = scope.for_media_type("episode") if @media_type == "tv"
        scope.all
      end

      def period_label
        case @period
        when "week" then "Last 7 days"
        when "month" then "Last 30 days"
        when "all" then "All time"
        else Date.today.year.to_s
        end
      end

      def compute_totals(plays)
        movies = plays.select {|p| p.item.media_type == "movie" }
        episodes = plays.select {|p| p.item.media_type == "episode" }

        unique_movies = movies.map {|p| p.item.tmdb_id }.uniq
        unique_shows = episodes.map {|p| p.item.parent_tmdb_id }.uniq
        unique_titles = unique_movies.size + unique_shows.size

        hours = plays.sum {|p| (p.item.runtime || 0).to_i } / 60.0

        pair_counts = Hash.new(0)
        plays.each {|p| pair_counts[[p.user_id, p.item_id]] += 1 }
        rewatches = pair_counts.values.sum {|c| c > 1 ? c - 1 : 0 }

        {
          plays: plays.size,
          unique_titles: unique_titles,
          movies_count: movies.size,
          episodes_count: episodes.size,
          hours_watched: hours.round(1),
          rewatches: rewatches
        }
      end

      def compute_headline(plays)
        total = plays.size
        hours = compute_totals(plays)[:hours_watched]
        {
          big_number: total,
          period_label: period_label,
          hours: hours,
          hours_sentence: humanize_hours(hours)
        }
      end

      def humanize_hours(hours)
        return "No time logged yet." if hours.zero?

        # Shave 10% off to account for credits / intros / skipped bits.
        total_hours = (hours * 0.9).round
        return "No time logged yet." if total_hours.zero?

        years, rem = total_hours.divmod(365 * 24)
        days, hours_left = rem.divmod(24)
        hour_phrase = "#{total_hours} hour#{"s" unless total_hours == 1} in front of the screen"
        return "#{hour_phrase}, start to finish." if years.zero? && days.zero?

        parts = []
        parts << "#{years} year#{"s" unless years == 1}" if years.positive?
        parts << "#{days} day#{"s" unless days == 1}" if days.positive?
        parts << "#{hours_left} hour#{"s" unless hours_left == 1}" if hours_left.positive? && years.zero?
        "#{hour_phrase}. That's #{join_phrase(parts)} of stories, start to finish."
      end

      def join_phrase(parts)
        return parts.first if parts.size <= 1

        "#{parts[0..-2].join(", ")} and #{parts.last}"
      end

      def compute_cards(plays)
        totals = compute_totals(plays)
        rhythm = compute_rhythm(plays)
        busiest = rhythm.max_by {|row| row[:total] }
        weeks = period_in_weeks
        avg = weeks.positive? ? (plays.size.to_f / weeks).round(1) : plays.size.to_f

        {
          different_titles: totals[:unique_titles],
          rewatches: totals[:rewatches],
          busiest: busiest && {label: busiest[:label], count: busiest[:total], context: busiest_context},
          average_per_week: avg
        }
      end

      def busiest_context
        case @period
        when "week" then "busiest day"
        when "month" then "busiest day"
        when "all" then "busiest year"
        else "busiest month"
        end
      end

      def period_in_weeks
        return 1 if @from.nil? || @to.nil?

        seconds = @to - @from
        (seconds / (7 * 86_400.0)).ceil.clamp(1, 10_000)
      end

      def compute_by_genre(plays)
        counts = Hash.new(0)
        samples = Hash.new {|h, k| h[k] = [] }
        plays.each do |play|
          primary = play.item.genres.first
          next unless primary

          counts[primary] += 1
          samples[primary] << play.item
        end
        counts.sort_by {|_, c| -c }.first(10).map do |name, count|
          {name: name, count: count, sample: pick_poster_item(samples[name])}
        end
      end

      def pick_poster_item(items)
        return nil if items.empty?

        resolved = items.map {|it| it.media_type == "episode" ? show_for(it) : it }.compact
        resolved.select {|it| it.poster_path && !it.poster_path.empty? }.sample ||
          items.find {|it| it.poster_path && !it.poster_path.empty? }
      end

      def show_for(episode)
        @show_cache ||= {}
        @show_cache[episode.parent_tmdb_id] ||= Item.where(media_type: "tv", tmdb_id: episode.parent_tmdb_id).first
      end

      def compute_rhythm(plays)
        return [] if plays.empty?

        bucket_fn, label_fn, all_keys_fn = pick_bucketing(plays)
        counts = {}
        plays.each do |play|
          key = bucket_fn.call(play.played_at)
          counts[key] ||= {movies: 0, episodes: 0}
          if play.item.media_type == "episode"
            counts[key][:episodes] += 1
          else
            counts[key][:movies] += 1
          end
        end

        keys = all_keys_fn ? all_keys_fn.call : counts.keys.sort
        rows = keys.map do |key|
          data = counts[key] || {movies: 0, episodes: 0}
          total = data[:movies] + data[:episodes]
          {label: label_fn.call(key), movies: data[:movies], episodes: data[:episodes], total: total}
        end
        peak_total = rows.map {|r| r[:total] }.max || 0
        rows.each {|r| r[:peak] = peak_total.positive? && r[:total] == peak_total }
        rows
      end

      def pick_bucketing(plays)
        today = Date.today
        case @period
        when "year"
          year = today.year
          [
            ->(t) { t.to_date.month },
            ->(m) { MONTH_NAMES[m - 1] },
            -> { (1..12).to_a }
          ]
        when "month"
          [
            ->(t) { t.to_date },
            ->(d) { d.strftime("%b %-d") },
            -> { ((today - 29)..today).to_a }
          ]
        when "week"
          [
            ->(t) { t.to_date },
            ->(d) { d.strftime("%a") },
            -> { ((today - 6)..today).to_a }
          ]
        when "all"
          years = plays.map {|p| p.played_at.year }.minmax
          [
            ->(t) { t.year },
            ->(y) { y.to_s },
            -> { (years.first..years.last).to_a }
          ]
        else
          span_days = ((plays.last.played_at - plays.first.played_at) / 86_400.0).ceil
          if span_days <= 90
            [->(t) { t.to_date }, ->(d) { d.strftime("%b %-d") }, nil]
          else
            [->(t) { [t.year, t.month] }, ->(k) { Date.new(k[0], k[1], 1).strftime("%b %Y") }, nil]
          end
        end
      end

      def compute_heatmap(_plays)
        tz = user_tz
        today = tz.to_local(Time.now.utc).to_date
        to_date = today
        from_date = to_date - 364

        scope = Play.for_user(@user).where { played_at >= Time.new(from_date.year, from_date.month, from_date.day) - (14 * 3600) }
        scope = scope.for_media_type("movie") if @media_type == "movie"
        scope = scope.for_media_type("episode") if @media_type == "tv"

        counts = Hash.new(0)
        scope.select_map(:played_at).each do |t|
          counts[tz.to_local(t.utc).to_date] += 1
        end

        filter_from = @from&.to_date
        filter_to = @to&.to_date

        in_filter = ->(d) {
          return true if filter_from.nil? && filter_to.nil?

          (filter_from.nil? || d >= filter_from) && (filter_to.nil? || d <= filter_to)
        }

        max_count = counts.select {|d, _| in_filter.call(d) }.values.max || 0

        cells = (from_date..to_date).map do |d|
          inside = in_filter.call(d)
          raw = counts[d]
          c = inside ? raw : 0
          {date: d, count: c, level: inside ? level_for(c, max_count) : 0, in_filter: inside}
        end

        biggest_date, biggest_count = counts.select {|d, _| in_filter.call(d) }.max_by {|_, c| c } || [nil, 0]

        {
          cells: cells,
          days_with_plays: counts.count {|d, c| in_filter.call(d) && c.positive? },
          biggest_day: biggest_date ? {date: biggest_date, count: biggest_count} : nil,
          max_count: max_count
        }
      end

      def level_for(count, max)
        return 0 if count.zero? || max.zero?
        return 4 if count >= (max * 0.75)
        return 3 if count >= (max * 0.5)
        return 2 if count >= (max * 0.25)

        1
      end

      def compute_top_shows(plays)
        episode_plays = plays.select {|p| p.item.media_type == "episode" }
        groups = episode_plays.group_by {|p| p.item.parent_tmdb_id }
        groups.map do |parent_tmdb, ps|
          sample = ps.first.item
          {
            parent_tmdb_id: parent_tmdb,
            name: sample.metadata["series_name"] || "Show #{parent_tmdb}",
            episode_count: ps.size,
            unique_episodes: ps.map(&:item_id).uniq.size
          }
        end.sort_by {|row| -row[:episode_count] }.first(10)
      end

      def compute_top_movies(plays)
        movie_plays = plays.select {|p| p.item.media_type == "movie" }
        counts = Hash.new(0)
        items = {}
        movie_plays.each do |p|
          counts[p.item_id] += 1
          items[p.item_id] = p.item
        end
        counts.sort_by {|_, c| -c }.first(10).map {|id, c| {item: items[id], count: c} }
      end

      def compute_top_cast(plays)
        people_counts = Hash.new(0)
        people_profiles = {}
        person_items = Hash.new {|h, k| h[k] = Hash.new(0) }
        item_labels = {}

        plays.each do |play|
          seen = {}
          Array(play.item.credits["cast"]).first(10).each do |actor|
            name = actor["name"]
            next if name.nil? || seen[name]

            seen[name] = true
            people_counts[name] += 1
            people_profiles[name] ||= actor["profile_path"]
            label = label_for_play(play, item_labels)
            person_items[name][label] += 1 if label
          end
        end

        people_counts.sort_by {|_, c| -c }.first(10).map do |name, count|
          top_label, _ = person_items[name].max_by {|_, c| c }
          {name: name, count: count, profile_path: people_profiles[name], top_item_title: top_label}
        end
      end

      def compute_top_directors(plays)
        people_counts = Hash.new(0)
        people_profiles = {}
        person_items = Hash.new {|h, k| h[k] = Hash.new(0) }
        item_labels = {}

        plays.each do |play|
          seen = {}
          Array(play.item.credits["crew"]).each do |crew|
            next unless %w[Director Writer Screenplay Creator].include?(crew["job"])

            name = crew["name"]
            next if name.nil? || seen[name]

            seen[name] = true
            people_counts[name] += 1
            people_profiles[name] ||= crew["profile_path"]
            label = label_for_play(play, item_labels)
            person_items[name][label] += 1 if label
          end
        end

        people_counts.sort_by {|_, c| -c }.first(10).map do |name, count|
          top_label, _ = person_items[name].max_by {|_, c| c }
          {name: name, count: count, profile_path: people_profiles[name], top_item_title: top_label}
        end
      end

      def label_for_play(play, cache)
        key = [play.item.media_type, play.item.media_type == "episode" ? play.item.parent_tmdb_id : play.item.tmdb_id]
        cache[key] ||= play.item.media_type == "episode" ? (play.item.metadata["series_name"] || "Show") : play.item.title
      end
    end
  end
end
