# frozen_string_literal: true

require "date"

module Rewind
  module Services
    # Play streaks: consecutive local calendar days with at least one play.
    #
    # Reads come from the derived `user_day_activity` table (migration 009),
    # which holds one row per user, media group and local day. That table is
    # maintained by Play's model hooks (single writes) and can always be rebuilt
    # from `plays` with .rebuild_user. Keeping it derived means the expensive
    # UTC -> local-day conversion happens once at write time, not per page load.
    class Streaks
      # Map the raw items.media_type onto the app's display groups, matching how
      # Services::Stats buckets media. Types that never appear as plays (series,
      # album, artist) map to nil and are skipped.
      MEDIA_GROUPS = {
        "movie" => "movie",
        "episode" => "series",
        "track" => "music"
      }.freeze

      class << self
        def group_for(media_type)
          MEDIA_GROUPS[media_type]
        end

        def tz_for(user)
          TZInfo::Timezone.get(user&.timezone || "UTC")
        rescue TZInfo::InvalidTimezoneIdentifier
          TZInfo::Timezone.get("UTC")
        end

        # UTC Time -> 'YYYY-MM-DD' in the user's local time zone.
        def local_day(played_at, tz)
          tz.to_local(played_at.utc).to_date.iso8601
        end

        def today_for(user)
          tz_for(user).to_local(Time.now.utc).to_date
        end

        # --- Maintenance (called from Play hooks) --------------------------

        def add_for_play(play)
          coords = coords_for(play)
          return unless coords

          add_activity(*coords)
        end

        def remove_for_play(play)
          coords = coords_for(play)
          return unless coords

          remove_activity(*coords)
        end

        def add_activity(user_id, media_group, day)
          activity
            .insert_conflict(
              target: %i[user_id media_group day],
              update: {play_count: Sequel[:play_count] + 1}
            )
            .insert(user_id:, media_group:, day:, play_count: 1)
        end

        def remove_activity(user_id, media_group, day)
          scope = activity.where(user_id:, media_group:, day:)
          scope.update(play_count: Sequel[:play_count] - 1)
          scope.where { play_count <= 0 }.delete
        end

        # --- Rebuild / verify (safety net, backfill, tz changes) -----------

        def rebuild_user(user)
          counts = computed_counts(user)

          Rewind.db.transaction do
            activity.where(user_id: user.id).delete
            next if counts.empty?

            rows = counts.map do |(media_group, day), play_count|
              {user_id: user.id, media_group:, day:, play_count:}
            end
            activity.multi_insert(rows)
          end
        end

        def rebuild_all
          User.each {|user| rebuild_user(user) }
        end

        # Daemon thread that rebuilds every user's streak table on a short
        # interval, as a self-healing guard against drift — a stale table could
        # otherwise show a broken streak. Started by `rewind run` only. Each
        # pass is wrapped so one bad user can't kill the loop.
        def start_thread(interval: Rewind.config.streak_rebuild_interval)
          Thread.new do
            loop do
              sleep interval
              begin
                rebuild_all
                Rewind.logger.info("[streaks] rebuilt all users")
              rescue StandardError => error
                Rewind.logger.error("[streaks] #{error.message}")
              end
            end
          end
        end

        # Recompute from `plays` and compare to the table without writing.
        # Returns an array of differences; empty means the table is in sync.
        def verify(user)
          expected = computed_counts(user)
          actual = {}
          activity.where(user_id: user.id).each do |row|
            actual[[row[:media_group], row[:day]]] = row[:play_count]
          end

          (expected.keys | actual.keys).filter_map do |key|
            exp = expected[key] || 0
            act = actual[key] || 0
            next if exp == act

            {media_group: key[0], day: key[1], expected: exp, actual: act}
          end
        end

        private def activity
          Rewind.db[:user_day_activity]
        end

        # {[media_group, day] => play_count} computed straight from `plays`.
        private def computed_counts(user)
          tz = tz_for(user)
          counts = Hash.new(0)

          Play.for_user(user)
              .exclude(played_at: nil)
              .join(:items, id: :item_id)
              .select_map([
                Sequel[:plays][:played_at],
                Sequel[:items][:media_type]
              ])
              .each do |played_at, media_type|
            group = group_for(media_type)
            next unless group && played_at

            counts[[group, local_day(played_at, tz)]] += 1
          end

          counts
        end

        # Play -> [user_id, media_group, day], or nil when it can't anchor a day
        # (no played_at) or isn't a streak-eligible media type.
        private def coords_for(play)
          return unless play.played_at

          media_type = Item.where(id: play.item_id).get(:media_type)
          group = group_for(media_type)
          return unless group

          user = User.where(id: play.user_id).first
          [play.user_id, group, local_day(play.played_at, tz_for(user))]
        end
      end

      def initialize(user:)
        @user = user
      end

      # Width of the activity strip shown on the card.
      STRIP_DAYS = 14

      def get_streaks(today: nil)
        today ||= self.class.today_for(@user)

        # No transaction: this only reads. Under the global :immediate mode a
        # transaction here would grab the write lock and hold it through the
        # query loop on every page render, starving the sync thread into
        # "database is locked". A play landing mid-computation is harmless.
        groups = group_islands
        by_media_group = {}
        MEDIA_GROUPS.values.uniq.each do |g|
          by_media_group[g] = summarize(groups[g] || [], today)
        end
        overall = summarize(overall_islands, today)

        {overall:, by_media_group:}
      end

      # Every run of consecutive days across all media types, as
      # [{start_day:, end_day:, length:}], via gaps-and-islands.
      private def overall_islands
        Rewind.db.fetch(<<~SQL, @user.id).all
          WITH days AS (
            SELECT DISTINCT day AS d
            FROM user_day_activity
            WHERE user_id = ?
          ),
          grp AS (
            SELECT d, julianday(d) - row_number() OVER (ORDER BY d) AS anchor
            FROM days
          )
          SELECT min(d) AS start_day, max(d) AS end_day, count(*) AS length
          FROM grp
          GROUP BY anchor
        SQL
      end

      # Same, partitioned by media group: {media_group => [islands]}.
      private def group_islands
        rows = Rewind.db.fetch(<<~SQL, @user.id).all
          WITH grp AS (
            SELECT media_group AS g, day AS d,
                   julianday(day) - row_number()
                     OVER (PARTITION BY media_group ORDER BY day) AS anchor
            FROM user_day_activity
            WHERE user_id = ?
          )
          SELECT g AS media_group, min(d) AS start_day, max(d) AS end_day,
                 count(*) AS length
          FROM grp
          GROUP BY g, anchor
        SQL

        rows.group_by {|row| row[:media_group] }
      end

      # Reduce a set of islands to everything the card needs: the current and
      # longest runs, whether the current run is a record, the previous best and
      # most recent runs, and a day-by-day strip for the last STRIP_DAYS.
      private def summarize(islands, today)
        if islands.empty?
          return {
            current: 0, longest: nil, is_record: false, current_range: nil,
            previous_best: nil, last_streak: nil,
            strip: strip_for([], nil, today)
          }
        end

        alive = [today.iso8601, (today - 1).iso8601]
        current_island = islands.find {|i| alive.include?(i[:end_day]) }
        last_island = islands.max_by {|i| i[:end_day] }
        others = islands - [current_island].compact
        best_other = others.max_by {|i| [i[:length], i[:end_day]] }

        current = current_island ? current_island[:length] : 0
        best_other_len = best_other ? best_other[:length] : 0
        is_record = current.positive? && current >= best_other_len
        highlight = current_island || last_island

        {
          current:,
          longest: island_hash(islands.max_by {|i| [i[:length], i[:end_day]] }),
          is_record:,
          current_range: current_island && island_hash(current_island),
          previous_best: best_other && island_hash(best_other),
          last_streak: island_hash(last_island),
          strip: strip_for(islands, highlight, today)
        }
      end

      private def island_hash(island)
        return unless island

        {
          length: island[:length], start: island[:start_day],
          end: island[:end_day]
        }
      end

      # The last STRIP_DAYS calendar days, oldest first, each flagged as watched
      # (falls in any island), part of the highlighted run, and/or today.
      private def strip_for(islands, highlight, today)
        (0...STRIP_DAYS).map do |offset|
          date = today - (STRIP_DAYS - 1 - offset)
          iso = date.iso8601
          {
            date:,
            watched: islands.any? {|i| covers?(i, iso) },
            in_streak: highlight ? covers?(highlight, iso) : false,
            today: date == today
          }
        end
      end

      private def covers?(island, iso)
        iso.between?(island[:start_day], island[:end_day])
      end
    end
  end
end
