# frozen_string_literal: true

module Rewind
  module Services
    # Pulls recent plays from every enabled source into the plays table. Runs
    # once per `run_once`, or continuously on a background thread. Idempotent:
    # each source tracks a cursor, and plays dedupe on
    # (source_id, source_event_id).
    module Sync
      def self.run_once
        started = Rewind.clock
        sources = Rewind::Source.where(enabled: true)
        sources.each do |source|
          sync_source(source)
        rescue Services::Jellyfin::AuthError => error
          # Leave the source enabled: a failure is often transient (expired
          # token, server restart), and disabling it would silently stop sync
          # until someone noticed. We log and retry on the next run instead.
          Rewind.logger.warn(
            "[sync] source #{source.id} unauthorized: #{error.message}"
          )
        rescue StandardError => error
          Rewind.logger.error("[sync] source #{source.id} failed: " \
                              "#{error.message}")
        end
        Rewind.logger.info(
          "[sync] run done: #{sources.count} sources in " \
          "#{Rewind.format_duration(Rewind.clock - started)}"
        )
      end

      def self.sync_source(source)
        started = Rewind.clock
        adapter = Sources.adapter_for(source)
        result = adapter.recent_plays(since: source.cursor)
        adopt_instance_id(source, result[:instance_id])

        if result[:plays].any? && source.instance_id.nil?
          message = "No Jellyfin ServerId in the response; " \
                    "skipped #{result[:plays].size} plays to avoid duplicates"
          Rewind.logger.error("[sync] source #{source.id}: #{message}")
          # Records (doesn't raise), so it won't be cleared until a later run
          # actually reaches the success path below.
          record_error(source, message)
          return
        end

        # Record each play independently so one locked write can't skip the
        # rest of the batch. A play SQLite was too busy to take is deferred (not
        # raised): we hold the cursor so the lookback re-offers it next run,
        # rather than stepping past it and losing it.
        outcomes = result[:plays].map {|play| record_play(source, play) }
        new_plays = outcomes.count(:written)
        deferred = outcomes.count(:deferred)

        if deferred.positive?
          message = "#{deferred} of #{result[:plays].size} plays deferred " \
                    "(database locked); cursor held for retry"
          Rewind.logger.warn("[sync] source #{source.id}: #{message}")
          record_error(source, message)
          return
        end

        # Bump the cursor directly: it's derived sync state, and a legacy source
        # still missing its instance_id would otherwise fail model validation.
        # Clearing the error here treats a past failure as transient.
        source.this.update(cursor: result[:cursor], last_synced_at: Time.now,
                           last_error_id: nil)
        Rewind.logger.info(
          "[sync] source #{source.id}: #{result[:plays].size} resolved, " \
          "#{new_plays} new in " \
          "#{Rewind.format_duration(Rewind.clock - started)}"
        )
      rescue StandardError => error
        record_error(source, error.message)
        raise # let run_once / sync_one keep their existing logging and abort
      end

      # Append a sync failure to the source's error log and point the source at
      # it. Dataset insert/update (no model validation) so it can't itself raise
      # and mask the original error. The row is kept after the error resolves.
      def self.record_error(source, message)
        id = Rewind.db[:source_errors].insert(
          source_id: source.id,
          message: message.to_s[0, 500],
          created_at: Time.now
        )
        source.this.update(last_error_id: id)
      end

      # Adopt the source's stable instance id (the ServerId that comes on every
      # Jellyfin payload) the first time we see it, and stamp any of this
      # instance's existing plays that predate the column. Keyed on instance_id,
      # plays then dedupe even after a source is deleted and re-added.
      def self.adopt_instance_id(source, instance_id)
        return if source.instance_id || instance_id.nil?

        source.update(instance_id:)
        # Backfill only this source's own (or orphaned) plays — never another
        # server's, and never overwrite an id that's already set.
        filled = Rewind::Play
                 .where(user_id: source.user_id, source: source.type,
                        instance_id: nil)
                 .where(Sequel.|({source_id: source.id}, {source_id: nil}))
                 .update(instance_id:)
        Rewind.logger.info(
          "[sync] source #{source.id}: instance #{instance_id}, " \
          "backfilled #{filled} plays"
        )
      end

      # Records one play as its own committed write. Returns :written on a new
      # play, :duplicate when it was already recorded, or :deferred when SQLite
      # was too busy to take the write (so the caller holds the cursor and the
      # lookback retries it next run). Any other error propagates.
      def self.record_play(source, play)
        # Both the pull and the webhook key a Jellyfin play on the same identity
        # (jellyfin:<ItemId>:<LastPlayedDate>), so whichever lands second trips
        # the (user_id, instance_id, source_event_id) unique index and is caught
        # below — no explicit dedup needed here.
        Rewind::Play.create(
          user_id: source.user_id,
          item_id: play[:item_id],
          source_id: source.id,
          instance_id: source.instance_id,
          source: source.type,
          source_event_id: play[:source_event_id],
          played_at: play[:played_at]
        )
        :written
      rescue Sequel::UniqueConstraintViolation
        :duplicate # already recorded on a previous sync
      rescue Sequel::DatabaseError => error
        raise unless database_locked?(error)

        Rewind.logger.warn(
          "[sync] source #{source.id}: deferred #{play[:source_event_id]} — " \
          "database locked"
        )
        :deferred
      end

      LOCK_PATTERN = /database is locked|SQLite3::BusyException/

      # A transient "database is locked" from SQLite's single-writer contention,
      # as opposed to a real database fault we must surface.
      def self.database_locked?(error)
        LOCK_PATTERN.match?(error.message.to_s) ||
          LOCK_PATTERN.match?(error.cause&.message.to_s)
      end

      # Daemon thread that syncs forever. Started by `rewind run` only.
      def self.start_thread(interval: Rewind.config.sync_interval)
        Thread.new do
          loop do
            begin
              run_once
            rescue StandardError => error
              Rewind.logger.error("[sync] #{error.message}")
            end
            sleep interval
          end
        end
      end
    end
  end
end
