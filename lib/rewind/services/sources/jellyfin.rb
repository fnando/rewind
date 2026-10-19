# frozen_string_literal: true

require "json"
require "time"

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
        # Re-scan this far back before the cursor every sync. Jellyfin dates a
        # play only once it settles, which can land after a mid-session sync has
        # already advanced the cursor past it; re-scanning the window catches
        # those late-dated plays (dedup on source_event_id keeps it idempotent).
        LOOKBACK_SECONDS = 24 * 60 * 60

        def initialize(source)
          @source = source
          @client = Services::Jellyfin.new(source.url,
                                           token: source.access_token)
          @series_tmdb = {}
          @folders = {}
          @albums_backfilled = {}
        end

        def recent_plays(since:)
          fetch_since = lookback(since)
          items = @client.played_items(user_id: @source.external_user_id,
                                       since: fetch_since)
          Rewind.logger.info(
            "[sync/jellyfin] fetched #{items.size} played items since " \
            "#{fetch_since.inspect} (cursor #{since.inspect})"
          )
          # First pass: dated items and non-audio. build_play returns nil for
          # dateless audio (recovered below).
          plays = items.filter_map {|item| build_play(item) }
          # Second pass: a track Jellyfin marks played but never dates still
          # belongs to a session — recover it onto its album's play time.
          plays += recover_dateless_audio(items, plays)
          # Advance to the newest real play date, but never behind the incoming
          # cursor (the lookback re-scans older items; it must not rewind us).
          latest = items.filter_map {|i| last_played(i) }.max
          cursor =
            if latest && since
              [latest, since].max_by {|value| Time.parse(value) }
            else
              latest || since
            end
          # Every Jellyfin payload carries the server's own id; grab it so plays
          # can be keyed on the instance (stable when a source is re-added).
          instance_id = items.filter_map {|i| presence(i["ServerId"]) }.first
          {plays: plays, cursor: cursor, instance_id: instance_id}
        end

        # Shift the cursor back by the lookback window so late-dated plays are
        # re-scanned. nil (full history) stays nil.
        private def lookback(since)
          return since if since.nil?

          (Time.parse(since.to_s) - LOOKBACK_SECONDS).iso8601
        rescue ArgumentError
          since
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
          # Dump the raw payload (debug only — it's noisy), whatever the type
          # or outcome.
          Rewind.logger.debug(
            "[sync/jellyfin] #{describe(item)} fields: #{JSON.generate(item)}"
          )
          resolved = resolve(item)
          return log_skip(item, "no TMDB/MusicBrainz match") unless resolved

          # Stamp the stable Jellyfin id so ratings can key off it. Audio gets
          # it through MusicBrainz (so unplayed siblings do too); everything
          # else is stamped here, its single choke point.
          stamp_jellyfin_id(resolved, item)

          # A genuine scrobble always carries a play date. A dateless Audio item
          # is a Jellyfin artifact — the IsPlayed flag set before the date is
          # written, or a stale flag. Anchoring it to the file's import date
          # would strand it on the wrong day, so leave it to the second pass,
          # which anchors it onto its album's session instead.
          played = last_played(item)
          return if played.nil? && item["Type"] == "Audio"

          # No real play date (movies/episodes)? Anchor to when it was added,
          # then when it aired, so it still lands on the timeline.
          anchor = played ||
                   presence(item["DateCreated"]) ||
                   presence(item["PremiereDate"])
          Rewind.logger.info(
            "[sync/jellyfin] resolved #{describe(item)} -> item #{resolved.id}"
          )
          {
            item_id: resolved.id,
            played_at: anchor && Time.parse(anchor),
            source_event_id: "jellyfin:#{item['Id']}:#{played || 'played'}"
          }
        rescue Services::TMDB::Error, Services::Jellyfin::Error => error
          log_skip(item, error.message)
        end

        # Record the Jellyfin id on a non-audio item (movie/episode/generic) so
        # its rating keys off a stable identity. Audio is handled in the music
        # path so unplayed album siblings get ids too.
        private def stamp_jellyfin_id(resolved, item)
          return if item["Type"] == "Audio"

          id = presence(item["Id"])
          return if id.nil? || resolved.jellyfin_id == id

          resolved.update(jellyfin_id: id)
        end

        # Tracks Jellyfin reports as played-but-dateless (no LastPlayedDate)
        # would otherwise vanish. Anchor each onto its album's session — the
        # earliest real play time of a same-album track in this batch — so an
        # album heard start-to-finish shows every track and groups as one.
        # No same-album session to anchor to → skip. Guards the double-count the
        # old import-date anchor caused: never add a dateless play for a track
        # that already has a real-dated one (in this batch or already stored).
        private def recover_dateless_audio(items, dated_plays)
          sessions = album_sessions(items)
          dated_item_ids = dated_plays.to_set {|p| p[:item_id] }

          items.filter_map do |item|
            next unless item["Type"] == "Audio" && last_played(item).nil?

            anchor = sessions[presence(item["ParentId"])]
            next log_skip(item, "no album session to anchor to") unless anchor

            resolved = resolve(item)
            next unless resolved
            next if dated_item_ids.include?(resolved.id)
            next if already_dated?(resolved.id)

            Rewind.logger.info(
              "[sync/jellyfin] recovered dateless #{describe(item)} -> " \
              "item #{resolved.id} @ #{anchor.iso8601}"
            )
            {
              item_id: resolved.id,
              played_at: anchor,
              source_event_id: "jellyfin:#{item['Id']}:played"
            }
          end
        end

        # album ParentId -> earliest real play time among this batch's dated
        # audio, the anchor for that album's dateless tracks.
        private def album_sessions(items)
          items.each_with_object({}) do |item, sessions|
            next unless item["Type"] == "Audio"

            played = last_played(item)
            parent = presence(item["ParentId"])
            next unless played && parent

            time = Time.parse(played)
            current = sessions[parent]
            sessions[parent] = time if current.nil? || time < current
          end
        end

        # Does this item already have a real-dated play stored? Keeps a dateless
        # recovery from doubling a track that synced with a date before.
        private def already_dated?(item_id)
          !Rewind::Play
            .where(user_id: @source.user_id, item_id: item_id)
            .exclude(Sequel.like(:source_event_id, "%:played"))
            .empty?
        end

        # Logs why an item isn't being recorded and returns nil, so callers can
        # `return log_skip(...)`.
        private def log_skip(item, reason)
          Rewind.logger.info(
            "[sync/jellyfin] skipped #{describe(item)} — #{reason}"
          )
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
          track = music_item(item)
          return unless track

          backfill_album(item)
          track
        end

        # The shared Jellyfin-Audio -> MusicBrainz track resolution, used both
        # for the played track and for each of its album siblings.
        private def music_item(item)
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
            length_ms: item["RunTimeTicks"].to_i / 10_000,
            track_number: positive_int(item["IndexNumber"]),
            disc_number: positive_int(item["ParentIndexNumber"]),
            release_date: premiere_date(item),
            genres: item["Genres"],
            jellyfin_id: presence(item["Id"]),
            album_jellyfin_id: presence(item["ParentId"])
          )
        end

        # Pull every track on the played track's album (even unplayed ones) so
        # the album page shows the full tracklist. Each sibling resolves through
        # the same MusicBrainz path, so a later play of one dedupes onto the
        # item created here, and re-resolving keeps its metadata current.
        # Fetched at most once per album per run (so N plays off one album = one
        # call), but always re-fetched on the next run — cheap, and it picks up
        # tracks added to the album since.
        private def backfill_album(played_item)
          album_id = presence(played_item["ParentId"])
          return unless album_id
          return if @albums_backfilled.key?(album_id)

          @albums_backfilled[album_id] = true
          @client.album_tracks(user_id: @source.external_user_id,
                               album_id: album_id).each do |sibling|
            music_item(sibling)
          end
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

        # A host-less Jellyfin image reference. The host is re-resolved from the
        # current source at serve time (see ViewHelper#remote_poster_url), so a
        # stored URL never goes stale across environments.
        private def primary_image_url(item_id, tag)
          return unless item_id && tag

          "/Items/#{item_id}/Images/Primary?tag=#{tag}"
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
