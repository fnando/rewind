# frozen_string_literal: true

require "time"

module Rewind
  module Services
    module Webhooks
      # Records plays from Jellyfin's generic webhook plugin — a push fallback
      # for the pull sync, which can miss a track when a client (e.g. Discrete)
      # never settles its LastPlayedDate. We act only on a completed playback
      # (PlayedToCompletion) and resolve the track from the payload's
      # MusicBrainz ids.
      #
      # Dedup is by identity, not time: the PlaybackStop payload carries the
      # track's stop time but not its LastPlayedDate, so we re-fetch that date
      # from Jellyfin and key the play on jellyfin:<ItemId>:<LastPlayedDate> —
      # exactly how the pull keys it. The unique index then collapses the two
      # into one row, immune to pauses. When Jellyfin never settled a date, we
      # fall back to the stop time; the pull can't key such a play either, so
      # there's nothing to collide with.
      module Jellyfin
        # Media types we record. Audio is the proven gap; widen as needed.
        SUPPORTED_TYPES = %w[Audio].freeze

        # Returns the created Play, or nil when the event is ignored/deduped.
        def self.record(payload)
          # Dump the raw payload (debug only — it's noisy), whatever the type or
          # outcome. Mirrors the pull sync's per-item dump, and shows which
          # fields Jellyfin actually sends (e.g. LastPlayedDate, PlayCount).
          Rewind.logger.debug(
            "[webhook/jellyfin] payload: #{JSON.generate(payload)}"
          )
          return unless actionable?(payload)

          source = source_for(payload)
          return log_skip(payload, "no matching Jellyfin source") unless source

          item = resolve(payload)
          return log_skip(payload, "could not resolve track") unless item

          jellyfin_id = presence(payload["ItemId"])
          archive(payload, item, source, jellyfin_id)

          # Prefer the track's LastPlayedDate (re-fetched from Jellyfin) so this
          # play keys the same as the pull's; fall back to the stop time when
          # Jellyfin never settled a date.
          last_played = fetch_last_played(source, jellyfin_id)
          anchor = last_played || payload["UtcTimestamp"]
          played_at = parse_time(anchor)
          return log_skip(payload, "no usable timestamp") unless played_at

          event_id = "jellyfin:#{jellyfin_id}:#{anchor}"
          play = create_play(source, item, event_id, played_at)
          Rewind.logger.info(
            "[webhook/jellyfin] recorded #{payload['Name'].inspect} -> " \
            "item #{item.id} @ #{played_at.utc.iso8601}"
          )
          play
        rescue Sequel::UniqueConstraintViolation
          nil # the pull (or a re-delivery) already recorded this play
        end

        # The track's LastPlayedDate as Jellyfin stores it (the raw string, so
        # it matches the pull's key byte-for-byte), or nil when absent/missing.
        # A re-fetch hiccup must never drop a play — we fall back to the stop
        # time — so every failure degrades to nil.
        def self.fetch_last_played(source, jellyfin_id)
          return unless jellyfin_id && presence(source.access_token)

          item = client_for(source).item(user_id: source.external_user_id,
                                         item_id: jellyfin_id)
          presence(item.dig("UserData", "LastPlayedDate"))
        rescue StandardError => error
          Rewind.logger.debug(
            "[webhook/jellyfin] LastPlayedDate re-fetch failed: " \
            "#{error.message}"
          )
          nil
        end

        def self.client_for(source)
          Services::Jellyfin.new(source.url,
                                 token: source.access_token,
                                 device_id: source.device_id)
        end

        # Record this id -> track + recording in the archive, and on the id's
        # first sighting run the re-tag healer so a re-tagged file's stranded
        # play is pulled onto the row the webhook just resolved. Mirrors the
        # pull's archive_track. Keyed on the payload's ServerId (per-instance).
        def self.archive(payload, item, source, jellyfin_id)
          instance = presence(payload["ServerId"]) || source.instance_id
          recording = presence(payload["Provider_musicbrainzrecording"])
          if recording && !JellyfinArchive.seen?(jellyfin_id, instance)
            JellyfinArchive.reconcile(
              target: item, recording_mbid: recording, instance_id: instance,
              user_id: source.external_user_id, client: client_for(source)
            )
          end
          JellyfinArchive.remember(item:, jellyfin_id:, media_type: "track",
                                   instance_id: instance,
                                   recording_mbid: recording)
        end

        def self.actionable?(payload)
          payload["NotificationType"] == "PlaybackStop" &&
            payload["PlayedToCompletion"] &&
            SUPPORTED_TYPES.include?(payload["ItemType"])
        end

        def self.source_for(payload)
          user_id = presence(payload["UserId"])
          return unless user_id

          Source.where(type: "jellyfin", external_user_id: user_id).first
        end

        # Prefer the already-synced track (no network); otherwise resolve via
        # MusicBrainz from the ids Jellyfin includes in the payload.
        def self.resolve(payload)
          jellyfin_id = presence(payload["ItemId"])
          existing =
            jellyfin_id &&
            Item.where(media_type: "track", jellyfin_id:).first
          existing || resolve_via_musicbrainz(payload)
        end

        def self.resolve_via_musicbrainz(payload)
          title = presence(payload["Name"])
          return unless title

          MusicBrainz.new.resolve(
            title:,
            artist: presence(payload["Artist"]),
            album: presence(payload["Album"]),
            release_track_mbid: presence(payload["Provider_musicbrainztrack"]),
            release_mbid: presence(payload["Provider_musicbrainzalbum"]),
            artist_mbid: presence(payload["Provider_musicbrainzartist"]),
            length_ms: payload["RunTimeTicks"].to_i / 10_000,
            release_date: presence(payload["PremiereDate"]),
            jellyfin_id: presence(payload["ItemId"])
          )
        end

        def self.create_play(source, item, event_id, played_at)
          Play.create(
            user_id: source.user_id,
            item_id: item.id,
            source: "jellyfin",
            # The source's instance_id, not the payload's ServerId, so it
            # matches the pull's key under the (user_id, instance_id,
            # source_event_id) unique index (same server id, but guaranteed).
            instance_id: source.instance_id,
            source_event_id: event_id,
            played_at:
          )
        end

        def self.parse_time(value)
          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end

        def self.presence(value)
          str = value.to_s.strip
          str.empty? ? nil : str
        end

        def self.log_skip(payload, reason)
          Rewind.logger.info(
            "[webhook/jellyfin] skipped #{payload['ItemType']} " \
            "#{payload['Name'].inspect} — #{reason}"
          )
          nil
        end
      end
    end
  end
end
