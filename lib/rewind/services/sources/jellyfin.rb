# frozen_string_literal: true

module Rewind
  module Services
    # Per-provider sync adapters. Each implements:
    #   recent_plays(since:) -> { plays: [{item_id:, played_at:,
    #                             source_event_id:}], cursor: <opaque> }
    #   resolve(external_item) -> Rewind::Item | nil
    module Sources
      def self.adapter_for(source)
        case source.type
        when "jellyfin" then Jellyfin.new(source)
        else raise Rewind::Error, "unknown source type: #{source.type}"
        end
      end

      # Resolves Jellyfin API items (Movie/Episode/Audio) into Items via TMDB /
      # MusicBrainz, and turns a user's played history into play records keyed
      # by the item id + its LastPlayedDate.
      class Jellyfin
        def initialize(source)
          @source = source
          @client = Services::Jellyfin.new(source.url,
                                           token: source.access_token)
          @series_tmdb = {}
        end

        def recent_plays(since:)
          items = @client.played_items(user_id: @source.external_user_id,
                                       since: since)
          plays = items.filter_map {|item| build_play(item) }
          cursor = items.filter_map {|i| last_played(i) }.max
          {plays: plays, cursor: cursor || since}
        end

        def resolve(item)
          case item["Type"]
          when "Movie" then resolve_movie(item)
          when "Episode" then resolve_episode(item)
          when "Audio" then resolve_audio(item)
          end
        end

        private def build_play(item)
          resolved = resolve(item)
          return unless resolved

          played = last_played(item)
          return unless played

          {
            item_id: resolved.id,
            played_at: Time.parse(played),
            source_event_id: "jellyfin:#{item['Id']}:#{played}"
          }
        rescue Services::TMDB::Error, Services::Jellyfin::Error => error
          Rewind.logger.warn("[sync/jellyfin] #{error.message}")
          nil
        end

        private def last_played(item)
          item.dig("UserData", "LastPlayedDate")
        end

        private def resolve_movie(item)
          ids = item["ProviderIds"] || {}
          tmdb = positive_int(ids["Tmdb"]) ||
                 lookup_tmdb_by_imdb(clean_imdb(ids["Imdb"]), "movie_results")
          return unless tmdb

          TMDB.new.movie(tmdb)
        end

        private def resolve_episode(item)
          season = positive_int(item["ParentIndexNumber"])
          episode = positive_int(item["IndexNumber"])
          series_tmdb = series_tmdb_id(item)
          return unless series_tmdb && season && episode

          TMDB.new.episode(series_tmdb, season, episode)
        end

        private def resolve_audio(item)
          title = presence(item["Name"])
          return unless title

          ids = item["ProviderIds"] || {}
          MusicBrainz.new.resolve(
            title: title,
            artist: presence(item["AlbumArtist"]) ||
                    presence(Array(item["Artists"]).first),
            album: presence(item["Album"]),
            recording_mbid: presence(ids["MusicBrainzRecording"]),
            release_group_mbid: presence(ids["MusicBrainzReleaseGroup"]),
            artist_mbid: presence(ids["MusicBrainzAlbumArtist"]) ||
                         presence(ids["MusicBrainzArtist"]),
            length_ms: item["RunTimeTicks"].to_i / 10_000
          )
        end

        # Episodes carry only their own ids; fetch the series' ProviderIds (once
        # per series) to get its TMDB id, falling back to IMDB lookups.
        private def series_tmdb_id(item)
          series_id = item["SeriesId"]
          @series_tmdb.fetch(series_id) do
            ids =
              if series_id
                @client.provider_ids(user_id: @source.external_user_id,
                                     item_id: series_id)
              else
                {}
              end
            episode_imdb = clean_imdb((item["ProviderIds"] || {})["Imdb"])
            @series_tmdb[series_id] =
              positive_int(ids["Tmdb"]) ||
              lookup_tmdb_by_imdb(clean_imdb(ids["Imdb"]), "tv_results") ||
              lookup_show_id_by_episode_imdb(episode_imdb)
          end
        end

        private def lookup_tmdb_by_imdb(imdb_id, result_key)
          return unless imdb_id

          found = TMDB.new.find_by_imdb(imdb_id)
          Array(found[result_key]).first&.dig("id")
        rescue Services::TMDB::Error
          nil
        end

        private def lookup_show_id_by_episode_imdb(episode_imdb)
          return unless episode_imdb

          found = TMDB.new.find_by_imdb(episode_imdb)
          Array(found["tv_episode_results"]).first&.dig("show_id")
        rescue Services::TMDB::Error
          nil
        end

        private def clean_imdb(value)
          str = value.to_s.strip
          str.match?(/\Att\d+\z/) ? str : nil
        end

        private def positive_int(value)
          str = value.to_s.strip
          return if str.empty?

          n = str.to_i
          n.positive? ? n : nil
        end

        private def presence(value)
          str = value.to_s.strip
          str.empty? ? nil : str
        end
      end
    end
  end
end
