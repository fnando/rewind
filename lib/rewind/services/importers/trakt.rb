# frozen_string_literal: true

require "zip"
require "time"

module Rewind
  module Services
    module Importers
      # Imports watchings, ratings, and reviews from a Trakt data export
      # (the `.zip` you download from trakt.tv) into a single Rewind user.
      # Items are resolved through TMDB using the tmdb ids in the archive, so
      # imported items match the rest of the app (runtime, genres, poster).
      class Trakt
        # Trakt rates 1-10; Rewind stores 1-5. Explicit mapping per the
        # product decision.
        RATING_MAP = {
          1 => 1, 2 => 1, 3 => 2, 4 => 2, 5 => 3,
          6 => 3, 7 => 3, 8 => 4, 9 => 4, 10 => 5
        }.freeze

        RATING_FILES = %w[
          ratings-movies.json ratings-shows.json ratings-episodes.json
        ].freeze

        COMMENT_FILES = %w[
          comments-movies.json comments-shows.json comments-episodes.json
        ].freeze

        def initialize(user:, archive:, out: $stdout)
          @user = user
          @archive = archive
          @out = out
          @tmdb = TMDB.new
          @stats = Hash.new(0)
        end

        def call
          Zip::File.open(@archive) do |zip|
            @zip = zip
            # Skip per-row streak hooks for the (potentially huge) import, then
            # rebuild the user's activity once at the end — far cheaper than an
            # upsert per play.
            Play.skip_activity_tracking { import_watchings }
            Services::Streaks.rebuild_user(@user)
            import_ratings
            import_reviews
          end
          @stats
        ensure
          @zip = nil
        end

        private def import_watchings
          read_entries("watched-history.json").each do |entry|
            item = resolve_media(entry)
            next skip unless item

            event_id = "trakt:history:#{entry['id']}"
            if Play.where(user_id: @user.id, source: "trakt",
                          source_event_id: event_id).first
              @stats[:plays_skipped] += 1
              next
            end

            Play.create(
              user_id: @user.id,
              item_id: item.id,
              played_at: parse_time(entry["watched_at"]) || Time.now,
              source: "trakt",
              source_event_id: event_id
            )
            @stats[:plays_created] += 1
          rescue TMDB::Error
            skip
          end
        end

        private def import_ratings
          RATING_FILES.each do |file|
            read_entries(file).each do |entry|
              rating = RATING_MAP[entry["rating"].to_i]
              item = rating && resolve_media(entry)
              next skip unless item

              upsert_user_item(item) {|ui| ui.rating = rating }
              @stats[:ratings_set] += 1
            rescue TMDB::Error
              skip
            end
          end
        end

        private def import_reviews
          COMMENT_FILES.each do |file|
            read_entries(file).each do |entry|
              comment = entry["comment"] || {}
              text = comment["comment"].to_s
              item = text.empty? ? nil : resolve_media(entry)
              next skip unless item

              upsert_user_item(item) do |ui|
                ui.review = text
                ui.review_created_at = parse_time(comment["created_at"])
                ui.review_updated_at = parse_time(comment["updated_at"])
              end
              @stats[:reviews_set] += 1
            rescue TMDB::Error
              skip
            end
          end
        end

        # Resolve the Rewind Item for a Trakt entry, based on its "type" and the
        # nested media object. Returns nil for unsupported types (season, list)
        # or when a tmdb id is missing.
        private def resolve_media(entry)
          case entry["type"]
          when "movie"
            tmdb_id = entry.dig("movie", "ids", "tmdb")
            tmdb_id && @tmdb.movie(tmdb_id)
          when "show"
            tmdb_id = entry.dig("show", "ids", "tmdb")
            tmdb_id && @tmdb.tv_item(tmdb_id)
          when "episode"
            show_tmdb = entry.dig("show", "ids", "tmdb")
            season = entry.dig("episode", "season")
            number = entry.dig("episode", "number")
            return unless show_tmdb && season && number

            @tmdb.episode(show_tmdb, season, number)
          end
        end

        private def upsert_user_item(item)
          key = item.rating_key
          ui = UserItem.where(user_id: @user.id, item_key: key).first ||
               UserItem.new(user_id: @user.id, item_key: key)
          yield ui
          ui.save
          ui
        end

        # Read and parse a JSON array from the archive, tolerating entries that
        # are missing or empty.
        private def read_entries(name)
          entry = @zip.find_entry(name)
          return [] unless entry

          data = JSON.parse(entry.get_input_stream.read)
          data.is_a?(Array) ? data : []
        rescue JSON::ParserError
          []
        end

        private def skip
          @stats[:skipped] += 1
          nil
        end

        private def parse_time(value)
          return if value.nil? || value.to_s.empty?

          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
