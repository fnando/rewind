# frozen_string_literal: true

module Rewind
  module Services
    module Webhooks
      module Jellyfin
        Error = Class.new(Rewind::Error)

        WATCHED_THRESHOLD = 0.85

        module_function def call(webhook:, payload:, **)
          notification_type = payload["NotificationType"] || payload["Event"]
          return :ignored_event unless accept_event?(notification_type, payload)

          # The per-instance token in the webhook URL already identifies the
          # instance; route the event to the user who claimed its UserId.
          mapping = find_mapping(
            webhook, payload["UserId"] || payload["userId"]
          )
          return :unknown_user unless mapping
          return :disabled_user if mapping.disabled?

          item = resolve_item(payload)
          return :unresolved_item unless item

          event_id = build_event_id(payload, notification_type)
          played_at =
            parse_time(payload["UtcTimestamp"] ||
                       payload["PlaybackStopTime"]) || Time.now

          existing = Play.where(integration_id: mapping.id,
                                source_event_id: event_id).first
          return existing if existing

          # Dedupe when the session id isn't a stable key (Jellyfin
          # sometimes sends it empty): don't record a second play for the
          # same item from the same mapping within one runtime window. Films
          # get a 30-minute floor; tracks use their real (short) length so a
          # legitimate song replay still records.
          window_seconds = payload["RunTimeTicks"].to_i / 10_000_000
          if item.media_type != "track" && window_seconds < 1800
            window_seconds = 1800
          end
          window_seconds = 30 if window_seconds < 1
          # NB: use Sequel[:played_at] (not a bare `played_at`) so the column is
          # compared — the local `played_at` above would otherwise shadow it.
          cutoff = Time.now - window_seconds
          recent = Play.where(integration_id: mapping.id, item_id: item.id)
                       .where(Sequel[:played_at] > cutoff)
                       .first
          return recent if recent

          mapping.update(last_event_at: Time.now)
          Play.create(
            user_id: mapping.user_id,
            item_id: item.id,
            integration_id: mapping.id,
            played_at:,
            source: "jellyfin",
            source_event_id: event_id
          )
        end

        # Route an event to the user who claimed this Jellyfin user id on the
        # given instance.
        module_function def find_mapping(webhook, user_id)
          return if user_id.to_s.strip.empty?

          target = normalize_uuid(user_id)
          webhook.integrations_dataset.all.find do |mapping|
            normalize_uuid(mapping.external_user_id) == target
          end
        end

        module_function def accept_event?(notification_type, payload)
          case notification_type
          when "PlaybackStop", "playback.stop"
            truthy?(payload["PlayedToCompletion"]) ||
              reached_watched_threshold?(payload)
          when "PlaybackProgress", "playback.progress"
            reached_watched_threshold?(payload)
          when "UserDataSaved", "userdata.saved"
            payload["SaveReason"] == "PlaybackFinished"
          else
            false
          end
        end

        module_function def reached_watched_threshold?(payload)
          position = payload["PlaybackPositionTicks"].to_i
          runtime = payload["RunTimeTicks"].to_i
          return false if runtime.zero?

          (position.to_f / runtime) >= WATCHED_THRESHOLD
        end

        module_function def truthy?(value)
          value == true || value.to_s.downcase == "true"
        end

        module_function def resolve_item(payload)
          item_type = payload["ItemType"]
          case item_type
          when "Movie"
            tmdb_id = tmdb_id_from(payload, "Provider_tmdb") ||
                      lookup_tmdb_by_imdb(
                        imdb_id_from(payload, "Provider_imdb"), "movie_results"
                      )
            return unless tmdb_id

            TMDB.new.movie(tmdb_id)
          when "Episode"
            season = positive_int(payload["SeasonNumber"] ||
                                  payload["ParentIndexNumber"])
            episode = positive_int(payload["EpisodeNumber"] ||
                                   payload["IndexNumber"])
            episode_imdb = imdb_id_from(payload, "Provider_imdb")
            series_tmdb = series_tmdb_id(payload) ||
                          lookup_tmdb_by_imdb(series_imdb_id(payload),
                                              "tv_results") ||
                          lookup_show_id_by_episode_imdb(episode_imdb)
            return unless series_tmdb && season && episode

            TMDB.new.episode(series_tmdb, season, episode)
          when "Audio"
            resolve_audio(payload)
          end
        end

        module_function def resolve_audio(payload)
          title = presence(payload["Name"])
          return unless title

          artist = presence(payload["AlbumArtist"]) ||
                   presence(Array(payload["Artists"]).first) ||
                   presence(payload["Artist"])
          mbid = presence(payload["Provider_MusicBrainzTrack"])
          length_ms = payload["RunTimeTicks"].to_i / 10_000

          MusicBrainz.new.resolve(
            artist: artist, album: presence(payload["Album"]),
            title: title, mbid: mbid, length_ms: length_ms
          )
        end

        module_function def presence(value)
          str = value.to_s.strip
          str.empty? ? nil : str
        end

        module_function def tmdb_id_from(payload, key)
          positive_int(payload[key] || payload["Provider_Tmdb"] || payload.dig(
            "ProviderIds", "Tmdb"
          ))
        end

        module_function def series_tmdb_id(payload)
          positive_int(
            payload["Provider_tmdb_series"] ||
            payload["SeriesProvider_tmdb"] ||
            payload.dig("SeriesProviderIds", "Tmdb")
          )
        end

        module_function def imdb_id_from(payload, key)
          clean_imdb(payload[key] || payload.dig("ProviderIds", "Imdb"))
        end

        module_function def series_imdb_id(payload)
          clean_imdb(
            payload["SeriesProvider_imdb"] ||
            payload.dig("SeriesProviderIds", "Imdb")
          )
        end

        module_function def clean_imdb(value)
          return if value.nil?

          str = value.to_s.strip
          str.match?(/\Att\d+\z/) ? str : nil
        end

        module_function def lookup_tmdb_by_imdb(imdb_id, result_key)
          return unless imdb_id

          found = TMDB.new.find_by_imdb(imdb_id)
          Array(found[result_key]).first&.dig("id")
        rescue TMDB::Error
          nil
        end

        module_function def lookup_show_id_by_episode_imdb(episode_imdb)
          return unless episode_imdb

          found = TMDB.new.find_by_imdb(episode_imdb)
          Array(found["tv_episode_results"]).first&.dig("show_id")
        rescue TMDB::Error
          nil
        end

        module_function def normalize_uuid(value)
          value.to_s.downcase.delete("-")
        end

        module_function def positive_int(value)
          return if value.nil?

          str = value.to_s.strip
          return if str.empty?

          n = str.to_i
          n.positive? ? n : nil
        end

        module_function def build_event_id(payload, notification_type)
          session = payload["PlaySessionId"]
          item_id = payload["Id"] || payload["ItemId"] || payload["id"]
          if session && !session.to_s.empty?
            return "session:#{session}:#{item_id}"
          end

          stamp = payload["UtcTimestamp"] || payload["PlaybackStopTime"] ||
                  Time.now.utc.iso8601
          "#{notification_type}:#{item_id}:#{stamp}"
        end

        module_function def parse_time(value)
          return if value.nil? || value.to_s.empty?

          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
