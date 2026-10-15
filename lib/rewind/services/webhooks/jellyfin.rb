# frozen_string_literal: true

module Rewind
  module Services
    module Webhooks
      module Jellyfin
        Error = Class.new(Rewind::Error)

        module_function

        WATCHED_THRESHOLD = 0.85

        def call(integration:, payload:, headers: {})
          notification_type = payload["NotificationType"] || payload["Event"]
          return :ignored_event unless accept_event?(notification_type, payload)

          external_user_id = payload["UserId"] || payload["userId"]
          if integration.external_user_id && external_user_id &&
             normalize_uuid(external_user_id) != normalize_uuid(integration.external_user_id)
            return :user_mismatch
          end

          item = resolve_item(payload)
          return :no_tmdb_id unless item

          event_id = build_event_id(payload, notification_type)
          played_at = parse_time(payload["UtcTimestamp"] || payload["PlaybackStopTime"]) || Time.now

          existing = Play.where(integration_id: integration.id, source_event_id: event_id).first
          return existing if existing

          # Dedupe when the session id isn't a stable key (Jellyfin sometimes sends it empty):
          # don't record a second play for the same item from the same integration within
          # one runtime window.
          window_seconds = (payload["RunTimeTicks"].to_i / 10_000_000)
          window_seconds = 1800 if window_seconds < 1800
          recent = Play.where(integration_id: integration.id, item_id: item.id)
            .where { played_at > (Time.now - window_seconds) }
            .first
          return recent if recent

          Play.create(
            user_id: integration.user_id,
            item_id: item.id,
            integration_id: integration.id,
            played_at: played_at,
            source: "jellyfin",
            source_event_id: event_id
          )
        end

        def accept_event?(notification_type, payload)
          case notification_type
          when "PlaybackStop", "playback.stop"
            truthy?(payload["PlayedToCompletion"]) || reached_watched_threshold?(payload)
          when "PlaybackProgress", "playback.progress"
            reached_watched_threshold?(payload)
          when "UserDataSaved", "userdata.saved"
            payload["SaveReason"] == "PlaybackFinished"
          else
            false
          end
        end

        def reached_watched_threshold?(payload)
          position = payload["PlaybackPositionTicks"].to_i
          runtime = payload["RunTimeTicks"].to_i
          return false if runtime.zero?

          (position.to_f / runtime) >= WATCHED_THRESHOLD
        end

        def truthy?(value)
          value == true || value.to_s.downcase == "true"
        end

        def resolve_item(payload)
          item_type = payload["ItemType"]
          case item_type
          when "Movie"
            tmdb_id = tmdb_id_from(payload, "Provider_tmdb") ||
                      lookup_tmdb_by_imdb(imdb_id_from(payload, "Provider_imdb"), "movie_results")
            return nil unless tmdb_id

            TMDB.new.movie(tmdb_id)
          when "Episode"
            season = positive_int(payload["SeasonNumber"] || payload["ParentIndexNumber"])
            episode = positive_int(payload["EpisodeNumber"] || payload["IndexNumber"])
            series_tmdb = series_tmdb_id(payload) ||
                          lookup_tmdb_by_imdb(series_imdb_id(payload), "tv_results") ||
                          lookup_show_id_by_episode_imdb(imdb_id_from(payload, "Provider_imdb"))
            return nil unless series_tmdb && season && episode

            TMDB.new.episode(series_tmdb, season, episode)
          end
        end

        def tmdb_id_from(payload, key)
          positive_int(payload[key] || payload["Provider_Tmdb"] || payload.dig("ProviderIds", "Tmdb"))
        end

        def series_tmdb_id(payload)
          positive_int(
            payload["Provider_tmdb_series"] ||
            payload["SeriesProvider_tmdb"] ||
            payload.dig("SeriesProviderIds", "Tmdb")
          )
        end

        def imdb_id_from(payload, key)
          clean_imdb(payload[key] || payload.dig("ProviderIds", "Imdb"))
        end

        def series_imdb_id(payload)
          clean_imdb(
            payload["SeriesProvider_imdb"] ||
            payload.dig("SeriesProviderIds", "Imdb")
          )
        end

        def clean_imdb(value)
          return nil if value.nil?

          str = value.to_s.strip
          str.match?(/\Att\d+\z/) ? str : nil
        end

        def lookup_tmdb_by_imdb(imdb_id, result_key)
          return nil unless imdb_id

          found = TMDB.new.find_by_imdb(imdb_id)
          Array(found[result_key]).first&.dig("id")
        rescue TMDB::Error
          nil
        end

        def lookup_show_id_by_episode_imdb(episode_imdb)
          return nil unless episode_imdb

          found = TMDB.new.find_by_imdb(episode_imdb)
          Array(found["tv_episode_results"]).first&.dig("show_id")
        rescue TMDB::Error
          nil
        end

        def normalize_uuid(value)
          value.to_s.downcase.delete("-")
        end

        def positive_int(value)
          return nil if value.nil?

          str = value.to_s.strip
          return nil if str.empty?

          n = str.to_i
          n.positive? ? n : nil
        end

        def build_event_id(payload, notification_type)
          session = payload["PlaySessionId"]
          item_id = payload["Id"] || payload["ItemId"] || payload["id"]
          return "session:#{session}:#{item_id}" if session && !session.to_s.empty?

          stamp = payload["UtcTimestamp"] || payload["PlaybackStopTime"] || Time.now.utc.iso8601
          "#{notification_type}:#{item_id}:#{stamp}"
        end

        def parse_time(value)
          return nil if value.nil? || value.to_s.empty?

          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
