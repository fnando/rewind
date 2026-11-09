# frozen_string_literal: true

require "json"
require "time"

module Rewind
  module Services
    # Per-provider sync adapters. Each implements:
    #   changes(since:) -> one page of the provider's play feed
    #   resolve_entry(entry) -> Rewind::Item | nil
    module Sources
      def self.adapter_for(source)
        case source.type
        when "jellyfin" then Jellyfin.new(source)
        else raise Rewind::Error, "unknown source type: #{source.type}"
        end
      end

      # Reads a user's play history from the Rewind Jellyfin plugin's changes
      # feed, and resolves each played Jellyfin item (Movie/Episode/Audio/...)
      # into an Item via TMDB / MusicBrainz.
      class Jellyfin
        def initialize(source)
          @source = source
          @client = Services::Jellyfin.new(source.url,
                                           token: source.access_token,
                                           device_id: source.device_id)
          @series_tmdb = {}
          @folders = {}
          @albums_backfilled = {}
          @artists_backfilled = {}
          @album_meta = {}
        end

        def server_id
          @client.server_id
        end

        def user_name
          @client.current_user_name
        end

        # One page of the plugin's changes feed after `since` (a sequence).
        def changes(since:)
          @client.rewind_changes(since:)
        end

        # The Item a plugin history entry played, or nil when it can't be
        # matched. Reads the live library item; when the server no longer has it
        # (deleted, re-tagged away), falls back to the Item already stamped with
        # its Jellyfin id, then to the plugin's snapshot of the item taken when
        # it played. Transport errors fetching the item propagate, so the caller
        # retries the entry instead of resolving it from a stale snapshot.
        def resolve_entry(entry)
          item_id = presence(entry["itemId"])
          return log_skip(snapshot_item(entry), "no item id") unless item_id

          live = @client.library_item(user_id: @source.external_user_id,
                                      item_id:)
          if live.nil?
            known = Rewind::Item.where(jellyfin_id: item_id).first
            return known if known
          end

          resolve_played(live || snapshot_item(entry))
        end

        private def resolve_played(item)
          Rewind.logger.debug(
            "[sync/jellyfin] #{describe(item)} fields: #{JSON.generate(item)}"
          )
          resolved = resolve(item)
          return log_skip(item, "no TMDB/MusicBrainz match") unless resolved

          # Stamp the stable Jellyfin id so ratings can key off it. Audio gets
          # it through MusicBrainz (so unplayed siblings do too); everything
          # else is stamped here, its single choke point.
          stamp_jellyfin_id(resolved, item)
          # Archive non-audio ids too (audio is archived in music_item). The
          # ledger is the full id history; only tracks carry a recording and
          # only they are healed.
          unless item["Type"] == "Audio"
            archive_remember(resolved, presence(item["Id"]),
                             resolved.media_type, instance_for(item))
          end
          resolved
        rescue Services::TMDB::Error, Services::Jellyfin::Error => error
          log_skip(item, error.message)
        end

        # The plugin's snapshot of an item (taken when it played) in the shape
        # of a Jellyfin API item, so `resolve` can match an item the library no
        # longer has. No Etag, so it's never mistaken for an unchanged item.
        def snapshot_item(entry)
          {
            "Id" => entry["itemId"],
            "Type" => entry["itemType"],
            "Name" => entry["name"],
            "ProviderIds" => entry["providerIds"] || {},
            "IndexNumber" => entry["indexNumber"],
            "ParentIndexNumber" => entry["seasonNumber"] || entry["discNumber"],
            "SeriesId" => entry["seriesId"],
            "SeriesName" => entry["seriesName"],
            "SeriesProviderIds" => entry["seriesProviderIds"],
            "ParentId" => entry["albumId"],
            "AlbumId" => entry["albumId"],
            "Album" => entry["album"],
            "Artists" => entry["artists"],
            "AlbumArtists" => entry["albumArtists"]&.map { {"Name" => it} },
            "ProductionYear" => entry["productionYear"],
            "Genres" => entry["genres"],
            "RunTimeTicks" => entry["runtimeTicks"]
          }.compact
        end

        # Match to TMDB/MusicBrainz; failing that, keep the item anyway by
        # building it straight from Jellyfin's own metadata (e.g. YouTube videos
        # imported by Pinchflat have no external ids). Audio always resolves via
        # MusicBrainz (synthetic ids), so it needs no fallback.
        #
        # Short-circuits when Jellyfin's Etag is unchanged: the stored item is
        # already current, so we skip the match, the re-write, and — for audio —
        # the album/artist backfill that lives in resolve_audio. A changed or
        # absent Etag falls through and re-resolves, so edits still land.
        def resolve(item)
          unchanged_item(item) || resolve_fresh(item)
        end

        private def resolve_fresh(item)
          resolved =
            case item["Type"]
            when "Movie"
              try_match { resolve_movie(item) } || generic_video(item, "movie")
            when "Episode"
              try_match { resolve_episode(item) } ||
              generic_episode(item) || generic_video(item, "movie")
            when "Audio"
              resolve_audio(item)
            when "MusicVideo"
              music_video(item)
            when "Video"
              # Loose videos (e.g. YouTube downloads) carry no external ids. If
              # they sit in a folder, treat the folder as a series; otherwise
              # keep them as standalone movies.
              generic_folder_episode(item) || generic_video(item, "movie")
            end
          stamp_source_etag(resolved, item)
          resolved
        end

        # The stored item for this Jellyfin payload when its Etag is unchanged,
        # so callers can skip re-resolving it. nil when new or changed.
        private def unchanged_item(item)
          id = presence(item["Id"])
          etag = presence(item["Etag"])
          return unless id && etag

          existing = Rewind::Item.where(jellyfin_id: id).first
          existing if existing && existing.source_etag == etag
        end

        private def stamp_source_etag(resolved, item)
          etag = presence(item["Etag"])
          return unless resolved && etag && resolved.source_etag != etag

          resolved.update(source_etag: etag)
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

        # Record the Jellyfin id on a non-audio item (movie/episode/generic) so
        # its rating keys off a stable identity. Audio is handled in the music
        # path so unplayed album siblings get ids too.
        private def stamp_jellyfin_id(resolved, item)
          return if item["Type"] == "Audio"

          id = presence(item["Id"])
          return if id.nil? || resolved.jellyfin_id == id

          resolved.update(jellyfin_id: id)
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
          backfill_artist_albums(item)
          track
        end

        # The shared Jellyfin-Audio -> MusicBrainz track resolution, used both
        # for the played track and for each of its album siblings. Skips the
        # re-resolve when the Etag is unchanged, so a backfill that re-lists an
        # album doesn't re-write every sibling.
        private def music_item(item)
          track = unchanged_item(item) || resolve_music_track(item)
          return unless track

          archive_track(track, item)
          track
        end

        private def resolve_music_track(item)
          title = presence(item["Name"])
          return unless title

          ids = item["ProviderIds"] || {}
          album_id = presence(item["ParentId"])
          release, artist_mbid = album_mbids(ids, album_id:)
          release_track = presence(ids["MusicBrainzTrack"]) ||
                          plugin_release_track(album_id, presence(item["Id"]))
          track = MusicBrainz.new.resolve(
            title: title,
            artist: album_artist_name(item, album_id),
            album: presence(item["Album"]),
            release_track_mbid: release_track,
            release_mbid: release,
            artist_mbid: artist_mbid,
            length_ms: item["RunTimeTicks"].to_i / 10_000,
            track_number: positive_int(item["IndexNumber"]),
            disc_number: positive_int(item["ParentIndexNumber"]),
            release_date: premiere_date(item),
            genres: item["Genres"],
            jellyfin_id: presence(item["Id"]),
            album_jellyfin_id: album_id
          )
          stamp_source_etag(track, item)
          track
        end

        # Record the track's Jellyfin id -> item + recording in the archive, and
        # on the id's first sighting run the re-tag healer (a re-tagged file has
        # a new id but the same recording, so this ties its stranded play to the
        # new row). Runs on the cached path too, so an already-synced library
        # still gets archived. The plugin recording lookup (an HTTP call, cached
        # per album per run) fires only on first sight; repeat syncs read the
        # recording from ProviderIds alone and `remember` keeps the stored one.
        private def archive_track(track, item)
          jellyfin_id = presence(item["Id"])
          return unless jellyfin_id

          instance = instance_for(item)
          ids = item["ProviderIds"] || {}
          recording = presence(ids["MusicBrainzRecording"])
          if JellyfinArchive.seen?(jellyfin_id, instance)
            return archive_remember(track, jellyfin_id, "track", instance,
                                    recording)
          end

          album_id = presence(item["ParentId"])
          recording ||= plugin_recording(album_id, jellyfin_id)
          JellyfinArchive.reconcile(
            target: track, recording_mbid: recording, instance_id: instance,
            user_id: @source.external_user_id, client: @client
          )
          archive_remember(track, jellyfin_id, "track", instance, recording)
        end

        private def archive_remember(item, jellyfin_id, media_type, instance,
                                     recording = nil)
          JellyfinArchive.remember(
            item:, jellyfin_id:, media_type:, instance_id: instance,
            recording_mbid: recording
          )
        end

        # The Jellyfin server id for an item. Prefer the payload's own ServerId;
        # fall back to the source's adopted instance id (nil only on the very
        # first sync, before it's adopted).
        private def instance_for(item)
          presence(item["ServerId"]) || @source.instance_id
        end

        # Pull every track on the played track's album (even unplayed ones) so
        # the album page shows the full tracklist. Each sibling resolves through
        # the same MusicBrainz path, so a later play of one dedupes onto the
        # item created here, and re-resolving keeps its metadata current.
        # Fetched at most once per album per run (so N plays off one album = one
        # call), but always re-fetched on the next run — cheap, and it picks up
        # tracks added to the album since.
        private def backfill_album(played_item)
          backfill_album_tracks(presence(played_item["ParentId"]))
        end

        # Resolve every track on an album (by its Jellyfin id) so the album's
        # full mbid tracklist exists. Fetched at most once per album per run.
        private def backfill_album_tracks(album_id)
          return unless album_id
          return if @albums_backfilled.key?(album_id)

          @albums_backfilled[album_id] = true
          @client.album_tracks(user_id: @source.external_user_id,
                               album_id: album_id).each do |sibling|
            music_item(sibling)
          end
        end

        # Pull every album the artist is credited on (even unplayed ones) so the
        # artist page shows the full discography — the album analogue of
        # backfill_album. Keyed on the artist's Jellyfin id from the played
        # track, fetched at most once per artist per run, re-fetched next run to
        # pick up newly-added albums. Each album resolves through the same
        # MusicBrainz path, so a later play of a track dedupes onto it.
        private def backfill_artist_albums(played_item)
          artist = Array(played_item["AlbumArtists"]).first ||
                   Array(played_item["ArtistItems"]).first
          artist_id = artist && presence(artist["Id"])
          return unless artist_id
          return if @artists_backfilled.key?(artist_id)

          @artists_backfilled[artist_id] = true
          @client.artist_albums(user_id: @source.external_user_id,
                                artist_id: artist_id).each do |album|
            music_album(album)
          end
        end

        # Backfill the full album list — and each album's tracks — for every
        # artist we already track. Each artist's Jellyfin id isn't stored on the
        # artist row, so read it from one of its albums' Jellyfin payloads.
        # Yields (artist title, album count) for progress reporting. Returns how
        # many artists were backfilled.
        def backfill_known_artists_albums
          count = 0
          Rewind::Item.where(media_type: "artist").each do |artist|
            artist_id = jellyfin_artist_id_for(artist)
            next unless artist_id

            albums = @client.artist_albums(user_id: @source.external_user_id,
                                           artist_id:)
            albums.each do |album|
              music_album(album)
              backfill_album_tracks(presence(album["Id"]))
            end
            count += 1
            yield(artist.title, albums.size) if block_given?
          end
          count
        end

        # After a full backfill has re-resolved every album, drop albums still
        # keyed by release group whose tracks have all re-parented onto a
        # release-keyed twin (leaving them childless). A release-group-only
        # album keeps its tracks, so it's never childless. DB-only; returns how
        # many were removed.
        def self.prune_orphaned_albums
          parented = Rewind::Item.where(media_type: "track")
                                 .exclude(parent_external_id: nil)
                                 .select(:parent_external_id)
          Rewind::Item.where(media_type: "album")
                      .where(Sequel.like(:external_id, "mbid:rg:%"))
                      .exclude(external_id: parented)
                      .delete
        end

        # The artist's Jellyfin id, read from one of its albums' Jellyfin
        # payloads. nil when none of its albums came from Jellyfin.
        private def jellyfin_artist_id_for(artist)
          album = Rewind::Item
                  .where(media_type: "album",
                         parent_external_id: artist.external_id)
                  .exclude(jellyfin_id: nil).first
          return unless album

          payload = @client.item(user_id: @source.external_user_id,
                                 item_id: album.jellyfin_id)
          credit = Array(payload["AlbumArtists"]).first ||
                   Array(payload["ArtistItems"]).first
          credit && presence(credit["Id"])
        end

        # The album analogue of music_item: resolves a Jellyfin MusicAlbum into
        # an album Item via MusicBrainz, without a track.
        private def music_album(item)
          title = presence(item["Name"])
          return unless title

          ids = item["ProviderIds"] || {}
          release, artist_mbid = album_mbids(ids,
                                             album_id: presence(item["Id"]))
          album = MusicBrainz.new.resolve_album(
            title: title,
            artist: album_artist_name(item, presence(item["Id"])),
            release_mbid: release,
            artist_mbid: artist_mbid,
            release_date: premiere_date(item),
            genres: item["Genres"],
            jellyfin_id: presence(item["Id"])
          )
          stamp_release_type(album, item)
          archive_remember(album, presence(item["Id"]), "album",
                           instance_for(item))
          album
        end

        # The release + album-artist mbids for an audio item, from its own
        # ProviderIds when present, else read from the album's file tags via the
        # AudioMetadata plugin. Jellyfin often omits these even for tagged files
        # — on the track, the album, or both — so either side fills the other.
        private def album_mbids(ids, album_id:)
          release = first_id(ids["MusicBrainzAlbum"])
          artist = first_id(ids["MusicBrainzAlbumArtist"]) ||
                   first_id(ids["MusicBrainzArtist"])
          if release.nil? || artist.nil?
            plugin = album_plugin_metadata(album_id)
            release ||= presence(plugin[:release])
            artist ||= presence(plugin[:artist])
          end
          [release, artist]
        end

        # The first id of a possibly multi-artist credit. A split release joins
        # its album-artist ids with ";" (sometimes "/"); mbids never contain
        # either, so take the first — the lead artist we parent under. Without
        # this a combined "a; b" becomes a broken "mbid:artist:a; b" id.
        private def first_id(value)
          presence(presence(value)&.split(%r{[;/]})&.first)
        end

        # The release-track mbid for one track, from the album's file tags via
        # the plugin, matched by the track's Jellyfin id. Used when Jellyfin's
        # own track payload omits MusicBrainzTrack.
        private def plugin_release_track(album_id, track_jellyfin_id)
          return unless album_id && track_jellyfin_id

          entry = Array(album_plugin_metadata(album_id)[:tracks])
                  .find {|t| t[:item_id] == track_jellyfin_id }
          entry && presence(entry[:release_track])
        end

        # The recording mbid for one track from the album's file tags via the
        # plugin, matched by Jellyfin id. Used when Jellyfin's own payload omits
        # MusicBrainzRecording — it's the archive's re-tag anchor.
        private def plugin_recording(album_id, track_jellyfin_id)
          return unless album_id && track_jellyfin_id

          entry = Array(album_plugin_metadata(album_id)[:tracks])
                  .find {|t| t[:item_id] == track_jellyfin_id }
          entry && presence(entry[:recording])
        end

        # Album MusicBrainz ids + release type from the AudioMetadata plugin,
        # fetched once per album id (empty hashes are cached too, so a
        # plugin-less server isn't re-hit).
        private def album_plugin_metadata(album_id)
          return {} unless album_id

          @album_meta[album_id] ||= @client.album_metadata(album_id)
        end

        # Cache the album's release type from the AudioMetadata plugin the first
        # time we see the album. Fetch-once: release type is stable, the plugin
        # is optional (nil when absent), and a `backfill artist-albums` re-run
        # fills any album still missing one.
        private def stamp_release_type(album, item)
          return unless album
          return if album.metadata["release_type"]

          id = presence(item["Id"]) || album.jellyfin_id
          type = album_plugin_metadata(id)[:release_type]
          return unless type

          album.update(metadata: album.metadata.merge("release_type" => type))
        end

        # Episodes carry only their own ids; fetch the series' ProviderIds (once
        # per series) to get its TMDB id, falling back to IMDB lookups.
        private def series_tmdb_id(item)
          series_id = item["SeriesId"]
          @series_tmdb.fetch(series_id) do
            # A snapshot (the item has left the library) carries the series'
            # ids itself; the series may be gone too, so don't ask for them.
            ids =
              if item["SeriesProviderIds"]
                item["SeriesProviderIds"]
              elsif series_id
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

        # The lead album-artist's name. The plugin's file tags are
        # authoritative — they join a split credit with ";" so we can take the
        # first cleanly (and a single name with a "/" survives). Jellyfin's own
        # fields are the fallback: its structured AlbumArtists splits a credit
        # per artist, while its flat AlbumArtist carries the combined "A / B"
        # for a split (and can be empty), so they're preferred in that order.
        private def album_artist_name(item, album_id)
          presence(album_plugin_metadata(album_id)[:artist_name]) ||
            presence(Array(item["AlbumArtists"]).first&.dig("Name")) ||
            presence(item["AlbumArtist"]) ||
            presence(Array(item["Artists"]).first)
        end

        # ----- Jellyfin-native fallback (no TMDB/MusicBrainz) -----

        # A MusicVideo resolves to its own media_type (not a movie) and links to
        # its artist by name. No external provider knows the video, so it's
        # built straight from Jellyfin's metadata. See Services::MusicVideo.
        private def music_video(item)
          title = presence(item["Name"])
          return unless title

          Services::MusicVideo.build(
            external_id: generic_external_id(item),
            title: title,
            artist_name: music_video_artist(item),
            runtime: ticks_to_minutes(item["RunTimeTicks"]),
            release_date: premiere_date(item),
            poster_path: primary_image_url(item["Id"],
                                           item.dig("ImageTags", "Primary")),
            jellyfin_id: presence(item["Id"])
          )
        end

        # The music video's artist name: Jellyfin's own Artists/AlbumArtists
        # fields first, then the parent folder of its path (videos are filed as
        # ".../Artist/Video.mp4").
        private def music_video_artist(item)
          presence(Array(item["Artists"]).first) ||
            presence(Array(item["AlbumArtists"]).first&.dig("Name")) ||
            presence(item["AlbumArtist"]) ||
            artist_from_path(item)
        end

        private def artist_from_path(item)
          path = presence(item["Path"])
          return unless path

          presence(File.basename(File.dirname(path)))
        end

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
