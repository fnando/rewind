# frozen_string_literal: true

require "date"

module Rewind
  module Services
    class Stats
      MONTH_NAMES = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze
      FULL_MONTH_NAMES = Date::MONTHNAMES.compact.freeze
      DIRECTOR_JOBS = %w[Director Writer Screenplay Creator].freeze

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
        return if value.nil? || value.to_s.strip.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def initialize(user:, media_type: "all", from: nil, to: nil,
                     period: "year")
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
          top_directors: compute_top_directors(plays),
          top_artists: compute_top_artists(plays),
          top_albums: compute_top_albums(plays),
          top_tracks: compute_top_tracks(plays)
        }
      end

      private def user_tz
        TZInfo::Timezone.get(@user&.timezone || "UTC")
      rescue TZInfo::InvalidTimezoneIdentifier
        TZInfo::Timezone.get("UTC")
      end

      private def load_plays
        scope = Play.for_user(@user)
                    .in_period(@from, @to)
                    .eager(:item)
                    .order(:played_at)

        scope = scope.for_media_type("movie") if @media_type == "movie"
        scope = scope.for_media_type("episode") if @media_type == "tv"
        scope = scope.for_media_type("track") if @media_type == "music"
        scope.all
      end

      private def period_label
        case @period
        when "week" then "Last 7 days"
        when "month" then "Last 30 days"
        when "all" then "All time"
        else Date.today.year.to_s
        end
      end

      private def compute_totals(plays)
        movies = plays.select {|p| p.item.media_type == "movie" }
        episodes = plays.select {|p| p.item.media_type == "episode" }
        tracks = plays.select {|p| p.item.media_type == "track" }

        unique_movies = movies.map {|p| p.item.external_id }.uniq
        unique_shows = episodes.map {|p| p.item.parent_external_id }.uniq
        unique_tracks = tracks.map {|p| p.item.external_id }.uniq
        unique_titles =
          unique_movies.size + unique_shows.size + unique_tracks.size

        # Screen time excludes music so the "in front of the screen" copy stays
        # honest; listening time is tracked separately.
        screen_hours =
          (movies + episodes).sum {|p| (p.item.runtime || 0).to_i } / 60.0
        listening_hours = tracks.sum {|p| (p.item.runtime || 0).to_i } / 60.0

        pair_counts = Hash.new(0)
        plays.each {|p| pair_counts[[p.user_id, p.item_id]] += 1 }
        rewatches = pair_counts.values.sum {|c| c > 1 ? c - 1 : 0 }

        {
          plays: plays.size,
          unique_titles: unique_titles,
          movies_count: movies.size,
          episodes_count: episodes.size,
          tracks_count: tracks.size,
          hours_watched: screen_hours.round(1),
          listening_hours: listening_hours.round(1),
          rewatches: rewatches
        }
      end

      private def compute_headline(plays)
        total = plays.size
        totals = compute_totals(plays)
        music = @media_type == "music"
        hours = music ? totals[:listening_hours] : totals[:hours_watched]
        sentence = music ? humanize_listening(hours) : humanize_hours(hours)
        {
          big_number: total,
          period_label: period_label,
          hours: hours,
          hours_sentence: sentence
        }
      end

      private def humanize_listening(hours)
        return "No listening logged yet." if hours.zero?

        total = hours.round
        return "Less than an hour of music so far." if total.zero?

        "#{total} #{total == 1 ? 'hour' : 'hours'} of music, in your ears."
      end

      private def humanize_hours(hours)
        return "No time logged yet." if hours.zero?

        # Shave 10% off to account for credits / intros / skipped bits.
        total_hours = (hours * 0.9).round
        return "No time logged yet." if total_hours.zero?

        years, rem = total_hours.divmod(365 * 24)
        days, hours_left = rem.divmod(24)
        suffix = "s" unless total_hours == 1
        hour_phrase =
          "#{total_hours} hour#{suffix} in front of the screen"
        return "#{hour_phrase}, start to finish." if years.zero? && days.zero?

        parts = []
        parts << "#{years} year#{'s' unless years == 1}" if years.positive?
        parts << "#{days} day#{'s' unless days == 1}" if days.positive?
        if hours_left.positive? && years.zero?
          parts << "#{hours_left} hour#{'s' unless hours_left == 1}"
        end
        "#{hour_phrase}. That's #{join_phrase(parts)} of stories, " \
          "start to finish."
      end

      private def join_phrase(parts)
        return parts.first if parts.size <= 1

        "#{parts[0..-2].join(', ')} and #{parts.last}"
      end

      private def compute_cards(plays)
        totals = compute_totals(plays)
        rhythm = compute_rhythm(plays)
        busiest = rhythm.max_by {|row| row[:total] }
        weeks = period_in_weeks
        avg = if weeks.positive?
                (plays.size.to_f / weeks).round(1)
              else
                plays.size.to_f
              end

        {
          different_titles: totals[:unique_titles],
          rewatches: totals[:rewatches],
          busiest: busiest && {
            label: busiest[:label], count: busiest[:total],
            context: busiest_context
          },
          average_per_week: avg
        }
      end

      private def busiest_context
        case @period
        when "week", "month" then "busiest day"
        when "all" then "busiest year"
        else "busiest month"
        end
      end

      private def period_in_weeks
        return 1 if @from.nil? || @to.nil?

        seconds = @to - @from
        (seconds / (7 * 86_400.0)).ceil.clamp(1, 10_000)
      end

      private def compute_by_genre(plays)
        counts = Hash.new(0)
        samples = Hash.new {|h, k| h[k] = [] }

        plays.each do |play|
          primary = play.item.genres.first
          next unless primary

          counts[primary] += 1
          samples[primary] << play.item
        end

        counts
          .sort_by {|_, c| -c }
          .first(10)
          .map do |name, count|
            {name: name, count: count, sample: pick_poster_item(samples[name])}
          end
      end

      private def pick_poster_item(items)
        return if items.empty?

        items
          .filter_map {|e| e.media_type == "episode" ? show_for(e) : e }
          .select {|e| e.poster_path && !e.poster_path.empty? }
          .sample ||
          items.find {|e| e.poster_path && !e.poster_path.empty? }
      end

      private def show_for(episode)
        @show_cache ||= {}
        @show_cache[episode.parent_external_id] ||=
          Item.where(media_type: "tv",
                     external_id: episode.parent_external_id).first
      end

      private def compute_rhythm(plays)
        return [] if plays.empty?

        bucket_fn, label_fn, all_keys_fn = pick_bucketing(plays)
        counts = {}

        plays.each do |play|
          key = bucket_fn.call(play.played_at)
          counts[key] ||= {movies: 0, episodes: 0, tracks: 0}

          case play.item.media_type
          when "episode" then counts[key][:episodes] += 1
          when "track" then counts[key][:tracks] += 1
          else counts[key][:movies] += 1
          end
        end

        keys = all_keys_fn ? all_keys_fn.call : counts.keys.sort

        rows = keys.map do |key|
          data = counts[key] || {movies: 0, episodes: 0, tracks: 0}
          total = data[:movies] + data[:episodes] + data[:tracks]

          {
            label: label_fn.call(key), movies: data[:movies],
            episodes: data[:episodes], tracks: data[:tracks], total: total
          }
        end

        peak_total = rows.map {|r| r[:total] }.max || 0
        rows.each do |r|
          r[:peak] = peak_total.positive? && r[:total] == peak_total
        end

        rows
      end

      private def pick_bucketing(plays)
        today = Date.today
        case @period
        when "year"
          [
            ->(t) { t.to_date.month },
            ->(m) { MONTH_NAMES[m - 1] },
            -> { (1..12).to_a }
          ]
        when "month"
          [
            lambda(&:to_date),
            ->(d) { d.strftime("%b %-d") },
            -> { ((today - 29)..today).to_a }
          ]
        when "week"
          [
            lambda(&:to_date),
            ->(d) { d.strftime("%a") },
            -> { ((today - 6)..today).to_a }
          ]
        when "all"
          years = plays.map {|p| p.played_at.year }.minmax
          [
            lambda(&:year),
            lambda(&:to_s),
            -> { (years.first..years.last).to_a }
          ]
        else
          seconds = plays.last.played_at - plays.first.played_at
          span_days = (seconds / 86_400.0).ceil
          if span_days <= 90
            [lambda(&:to_date), ->(d) { d.strftime("%b %-d") }, nil]
          else
            [
              ->(t) { [t.year, t.month] },
              ->(k) { Date.new(k[0], k[1], 1).strftime("%b %Y") },
              nil
            ]
          end
        end
      end

      private def compute_heatmap(_plays)
        tz = user_tz
        today = tz.to_local(Time.now.utc).to_date
        to_date = today
        from_date = to_date - 364

        scope = Play.for_user(@user).where do
          played_at >= Time.new(from_date.year, from_date.month,
                                from_date.day) - (14 * 3600)
        end
        scope = scope.for_media_type("movie") if @media_type == "movie"
        scope = scope.for_media_type("episode") if @media_type == "tv"
        scope = scope.for_media_type("track") if @media_type == "music"

        counts = Hash.new(0)
        scope.select_map(:played_at).each do |t|
          counts[tz.to_local(t.utc).to_date] += 1
        end

        filter_from = @from&.to_date
        filter_to = @to&.to_date

        in_filter = lambda {|d|
          return true if filter_from.nil? && filter_to.nil?

          (filter_from.nil? || d >= filter_from) &&
            (filter_to.nil? || d <= filter_to)
        }

        max_count = counts.select {|d, _| in_filter.call(d) }.values.max || 0

        cells = (from_date..to_date).map do |d|
          inside = in_filter.call(d)
          raw = counts[d]
          c = inside ? raw : 0
          {
            date: d, count: c, level: inside ? level_for(c, max_count) : 0,
            in_filter: inside
          }
        end

        biggest_date, biggest_count =
          counts
          .select {|d, _| in_filter.call(d) }
          .max_by {|_, c| c } || [nil, 0]

        {
          cells: cells,
          days_with_plays: counts.count do |d, c|
            in_filter.call(d) && c.positive?
          end,
          biggest_day: if biggest_date
                         {
                           date: biggest_date,
                           count: biggest_count
                         }
                       end,
          max_count: max_count
        }
      end

      private def level_for(count, max)
        return 0 if count.zero? || max.zero?
        return 4 if count >= (max * 0.75)
        return 3 if count >= (max * 0.5)
        return 2 if count >= (max * 0.25)

        1
      end

      private def compute_top_shows(plays)
        plays
          .select {|p| p.item.media_type == "episode" }
          .group_by {|p| p.item.parent_external_id }
          .map {|parent_external, ps| show_row(parent_external, ps) }
          .sort_by {|row| -row[:episode_count] }
          .first(10)
      end

      private def show_row(parent_external, ps)
        sample = ps.first.item
        {
          parent_external_id: parent_external,
          name: sample.metadata["series_name"] || "Show #{parent_external}",
          episode_count: ps.size,
          unique_episodes: ps.map(&:item_id).uniq.size
        }
      end

      private def compute_top_movies(plays)
        movie_plays = plays.select {|p| p.item.media_type == "movie" }
        counts = Hash.new(0)
        items = {}

        movie_plays.each do |p|
          counts[p.item_id] += 1
          items[p.item_id] = p.item
        end

        counts
          .sort_by {|_, c| -c }
          .first(10)
          .map {|id, c| {item: items[id], count: c} }
      end

      private def track_plays(plays)
        plays.select {|p| p.item.media_type == "track" }
      end

      private def compute_top_artists(plays)
        counts = Hash.new(0)
        track_plays(plays).each do |p|
          id = p.item.metadata["artist_external_id"]
          counts[id] += 1 if id
        end
        rank_music(counts)
      end

      private def compute_top_albums(plays)
        counts = Hash.new(0)
        track_plays(plays).each do |p|
          id = p.item.metadata["album_external_id"]
          counts[id] += 1 if id
        end
        rank_music(counts)
      end

      private def compute_top_tracks(plays)
        tracks = track_plays(plays)
        return [] if tracks.empty?

        counts = Hash.new(0)
        items = {}
        tracks.each do |p|
          counts[p.item_id] += 1
          items[p.item_id] = p.item
        end

        albums = music_items_by_external_id(
          items.values.map {|i| i.metadata["album_external_id"] }
        )

        counts.sort_by {|_, c| -c }.first(10).map do |id, count|
          track = items[id]
          {
            item: track, count: count,
            album: albums[track.metadata["album_external_id"]]
          }
        end
      end

      # Resolve a {external_id => play_count} hash into ranked rows carrying the
      # artist/album Item (for its name and artwork), mirroring top_shows.
      private def rank_music(counts)
        return [] if counts.empty?

        items = music_items_by_external_id(counts.keys)

        counts.sort_by {|_, c| -c }.first(10).map do |external_id, count|
          item = items[external_id]
          {
            external_id: external_id, count: count, item: item,
            name: item&.title || "Unknown"
          }
        end
      end

      private def music_items_by_external_id(external_ids)
        ids = external_ids.compact.uniq
        return {} if ids.empty?

        Item.where(external_id: ids).all.each_with_object({}) do |item, hash|
          hash[item.external_id] = item
        end
      end

      private def compute_top_cast(plays)
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

        people_counts
          .sort_by {|_, c| -c }
          .first(10)
          .map do |name, count|
            top_label, _ = person_items[name].max_by {|_, c| c }
            {
              name: name, count: count, profile_path: people_profiles[name],
              top_item_title: top_label
            }
          end
      end

      private def compute_top_directors(plays)
        people_counts = Hash.new(0)
        people_profiles = {}
        person_items = Hash.new {|h, k| h[k] = Hash.new(0) }
        item_labels = {}

        plays.each do |play|
          seen = {}
          Array(play.item.credits["crew"]).each do |crew|
            next unless DIRECTOR_JOBS.include?(crew["job"])

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

          {
            name: name, count: count, profile_path: people_profiles[name],
            top_item_title: top_label
          }
        end
      end

      private def label_for_play(play, cache)
        item = play.item
        episode = item.media_type == "episode"
        key = [
          item.media_type,
          episode ? item.parent_external_id : item.external_id
        ]

        cache[key] ||= if episode
                         item.metadata["series_name"] || "Show"
                       else
                         item.title
                       end
      end
    end
  end
end
