# frozen_string_literal: true

require "time"

module Rewind
  module Services
    module Webhooks
      # Records plays from Jellyfin's generic webhook plugin — a push fallback
      # for the pull sync, which can miss a track when a client (e.g. Discrete)
      # never settles its LastPlayedDate. We act only on a completed playback,
      # resolve the track straight from the payload's MusicBrainz ids, and dedup
      # against an overlapping pull play with a tight time window.
      module Jellyfin
        # Media types we record. Audio is the proven gap; widen as needed.
        SUPPORTED_TYPES = %w[Audio].freeze

        # Returns the created Play, or nil when the event is ignored/deduped.
        def self.record(payload)
          return unless actionable?(payload)

          source = source_for(payload)
          return log_skip(payload, "no matching Jellyfin source") unless source

          item = resolve(payload)
          return log_skip(payload, "could not resolve track") unless item

          played_at = parse_time(payload["UtcTimestamp"])
          return log_skip(payload, "no usable timestamp") unless played_at
          if Play.jellyfin_recorded_near?(user_id: source.user_id,
                                          item_id: item.id, played_at:)
            return log_skip(payload, "pull already recorded it " \
                                     "(within #{Play::JELLYFIN_DEDUP_WINDOW}s)")
          end

          play = create_play(source, item, payload, played_at)
          Rewind.logger.info(
            "[webhook/jellyfin] recorded #{payload['Name'].inspect} -> " \
            "item #{item.id} @ #{played_at.utc.iso8601}"
          )
          play
        rescue Sequel::UniqueConstraintViolation
          nil # exact re-delivery of the same event
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
            recording_mbid: presence(payload["Provider_musicbrainzrecording"]),
            release_group_mbid:
              presence(payload["Provider_musicbrainzreleasegroup"]),
            artist_mbid: presence(payload["Provider_musicbrainzartist"]),
            length_ms: payload["RunTimeTicks"].to_i / 10_000,
            release_date: presence(payload["PremiereDate"]),
            jellyfin_id: presence(payload["ItemId"])
          )
        end

        def self.create_play(source, item, payload, played_at)
          Play.create(
            user_id: source.user_id,
            item_id: item.id,
            source: "jellyfin",
            instance_id: presence(payload["ServerId"]),
            source_event_id: "jellyfin:#{payload['ItemId']}:" \
                             "#{payload['UtcTimestamp']}",
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
