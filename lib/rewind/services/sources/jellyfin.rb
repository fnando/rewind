# frozen_string_literal: true

require "json"

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
          @folders = {}
        end

        def recent_plays(since:)
          items = @client.played_items(user_id: @source.external_user_id,
                                       since: since)
          Rewind.logger.info(
            "[sync/jellyfin] fetched #{items.size} played items since " \
            "#{since.inspect}"
          )
          plays = items.filter_map {|item| build_play(item) }
          cursor = items.filter_map {|i| last_played(i) }.max
          {plays: plays, cursor: cursor || since}
        end

        # Match to TMDB/MusicBrainz; failing that, keep the item anyway by
        # building it straight from Jellyfin's own metadata (e.g. YouTube videos
        # imported by Pinchflat have no external ids). Audio always resolves via
        # MusicBrainz (synthetic ids), so it needs no fallback.
        def resolve(item)
          case item["Type"]
          when "Movie"
            try_match { resolve_movie(item) } || generic_video(item, "movie")
          when "Episode"
            try_match { resolve_episode(item) } ||
              generic_episode(item) || generic_video(item, "movie")
          when "Audio"
            resolve_audio(item)
          when "Video", "MusicVideo"
            # Loose videos (e.g. YouTube downloads) carry no external ids. If
            # they sit in a folder, treat the folder as a series; otherwise
            # keep them as standalone movies.
            generic_folder_episode(item) || generic_video(item, "movie")
          end
        end

        # Runs a TMDB/MusicBrainz match but swallows lookup errors so a flaky
        # match (e.g. a bogus provider id) still falls through to the
        # Jellyfin-native fallback instead of dropping the play.
        private def try_match
          yield
        rescue Services::TMDB::Error, Services::Jellyfin::Error => error
          Rewind.logger.info("[sync/jellyfin] match failed: #{error.message}")
          nil
        end

        private def build_play(item)
          resolved = resolve(item)
          return log_skip(item, "no TMDB/MusicBrainz match") unless resolved

          played = last_played(item)
          return log_skip(item, "no play date") unless played

          Rewind.logger.info(
            "[sync/jellyfin] resolved #{describe(item)} -> item #{resolved.id}"
          )
          {
            item_id: resolved.id,
            played_at: Time.parse(played),
            source_event_id: "jellyfin:#{item['Id']}:#{played}"
          }
        rescue Services::TMDB::Error, Services::Jellyfin::Error => error
          log_skip(item, error.message)
        end

        # Logs why an item isn't being recorded and returns nil, so callers can
        # `return log_skip(...)`.
        private def log_skip(item, reason)
          Rewind.logger.info(
            "[sync/jellyfin] skipped #{describe(item)} — #{reason}"
          )
          # Dump what Jellyfin gave us, so we can see what a fallback could use.
          Rewind.logger.info("[sync/jellyfin]   fields: #{JSON.generate(item)}")
          nil
        end

        private def describe(item)
          "#{item['Type']} #{item['Name'].inspect} (#{item['Id']})"
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

        # ----- Jellyfin-native fallback (no TMDB/MusicBrainz) -----

        private def generic_video(item, media_type)
          title = presence(item["Name"])
          return unless title

          upsert_item(
            media_type: media_type,
            external_id: generic_external_id(item),
            title: title,
            release_date: premiere_date(item),
            runtime: ticks_to_minutes(item["RunTimeTicks"]),
            poster_path: primary_image_url(item["Id"],
                                           item.dig("ImageTags", "Primary")),
            metadata: {"source" => "jellyfin"}
          )
        end

        private def generic_episode(item)
          title = presence(item["Name"])
          series_id = presence(item["SeriesId"])
          return unless title && series_id

          series = ensure_generic_series(item, series_id)
          upsert_item(
            media_type: "episode",
            external_id: generic_external_id(item),
            parent_external_id: series.external_id,
            title: title,
            season_number: positive_int(item["ParentIndexNumber"]),
            episode_number: positive_int(item["IndexNumber"]),
            release_date: premiere_date(item),
            runtime: ticks_to_minutes(item["RunTimeTicks"]),
            poster_path: primary_image_url(item["Id"],
                                           item.dig("ImageTags", "Primary")),
            metadata: {
              "series_name" => presence(item["SeriesName"]),
              "source" => "jellyfin"
            }
          )
        end

        # When a loose video lives in a sub-folder, people often name the folder
        # after the "show" (a course, a concert series). Use that folder as the
        # series. Loose files in the library root have no such folder.
        private def generic_folder_episode(item)
          title = presence(item["Name"])
          folder = parent_folder(item)
          return unless title && folder

          series = ensure_folder_series(folder)
          upsert_item(
            media_type: "episode",
            external_id: generic_external_id(item),
            parent_external_id: series.external_id,
            title: title,
            release_date: premiere_date(item),
            runtime: ticks_to_minutes(item["RunTimeTicks"]),
            poster_path: primary_image_url(item["Id"],
                                           item.dig("ImageTags", "Primary")),
            metadata: {"series_name" => folder["Name"], "source" => "jellyfin"}
          )
        end

        # Types that are a library, not a content folder.
        LIBRARY_ROOT_TYPES = %w[
          CollectionFolder UserRootFolder AggregateFolder
        ].freeze

        # The containing Folder to treat as a series, or nil. A video's parent
        # is NOT a series when it's a library (CollectionFolder) or the
        # library's own top folder (a Folder sitting directly under one) — only
        # genuinely nested folders become series.
        private def parent_folder(item)
          parent_id = presence(item["ParentId"])
          return unless parent_id

          @folders.fetch(parent_id) do
            @folders[parent_id] = series_folder(parent_id)
          end
        end

        private def series_folder(folder_id)
          folder = fetch_item(folder_id)
          return unless folder["Type"] == "Folder"

          grandparent_id = presence(folder["ParentId"])
          return unless grandparent_id

          grandparent = fetch_item(grandparent_id)
          return if LIBRARY_ROOT_TYPES.include?(grandparent["Type"])

          folder
        end

        private def fetch_item(item_id)
          @client.item(user_id: @source.external_user_id, item_id: item_id)
        end

        private def ensure_folder_series(folder)
          upsert_item(
            media_type: "series",
            external_id: "jellyfin:#{folder['Id']}",
            title: presence(folder["Name"]) || "Unknown series",
            poster_path: primary_image_url(
              folder["Id"], folder.dig("ImageTags", "Primary")
            ),
            metadata: {
              "series_name" => presence(folder["Name"]),
              "source" => "jellyfin"
            }
          )
        end

        private def ensure_generic_series(item, series_id)
          upsert_item(
            media_type: "series",
            external_id: "jellyfin:#{series_id}",
            title: presence(item["SeriesName"]) || "Unknown series",
            poster_path: primary_image_url(
              series_id, presence(item["SeriesPrimaryImageTag"])
            ),
            metadata: {
              "series_name" => presence(item["SeriesName"]),
              "source" => "jellyfin"
            }
          )
        end

        # Prefer the stable YouTube id (survives re-imports) over Jellyfin's.
        private def generic_external_id(item)
          yt = presence(item.dig("ProviderIds", "youtube"))
          yt ? "youtube:#{yt}" : "jellyfin:#{item['Id']}"
        end

        private def primary_image_url(item_id, tag)
          return unless item_id && tag

          base = @source.url.to_s.sub(%r{/+\z}, "")
          "#{base}/Items/#{item_id}/Images/Primary?tag=#{tag}"
        end

        private def premiere_date(item)
          premiere = presence(item["PremiereDate"])
          return premiere[0, 10] if premiere

          year = item["ProductionYear"]
          year ? "#{year}-01-01" : nil
        end

        private def ticks_to_minutes(ticks)
          minutes = (ticks.to_i / 600_000_000.0).round
          minutes.positive? ? minutes : nil
        end

        private def upsert_item(media_type:, external_id:, **attrs)
          existing = Rewind::Item.where(media_type: media_type,
                                        external_id: external_id).first
          attrs = attrs.merge(fetched_at: Time.now)
          if existing
            existing.update(attrs)
            existing
          else
            Rewind::Item.create(
              attrs.merge(media_type: media_type, external_id: external_id)
            )
          end
        end
      end
    end
  end
end
