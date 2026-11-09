# frozen_string_literal: true

module Rewind
  module Services
    # Mirrors each enabled source's play history from the Rewind Jellyfin
    # plugin's changes feed into the plays table. Runs once per `run_once`, or
    # continuously on a background thread.
    #
    # The plugin owns play detection: one record per playback session, with a
    # stable id, and its own call on whether the play counts (scrobbled). A
    # record re-appears in the feed whenever it changes (progress settles, the
    # scrobble rules are re-evaluated, details are filled in, it's deleted), so
    # every entry is applied as an upsert keyed on that id. Each source keeps
    # the feed's sequence number as its cursor.
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
        adopt_instance_id(source, adapter)
        refresh_user_name(source, adapter)
        tally = Hash.new(0)
        # Read the stored cursor, not the (possibly stale) loaded object's.
        since = source.this.get(:cursor).to_i

        loop do
          page = adapter.changes(since:)
          entries = Array(page["items"])
          # Apply each entry as its own committed write, so one locked write
          # can't skip the rest. A deferred entry holds the cursor: the page is
          # re-read next run and re-applied idempotently.
          entries.each do |entry|
            tally[record_entry(source, adapter, entry)] += 1
          end

          if tally[:deferred].positive?
            message = "#{tally[:deferred]} of #{entries.size} plays deferred " \
                      "(database locked); cursor held for retry"
            Rewind.logger.warn("[sync] source #{source.id}: #{message}")
            record_error(source, message)
            return
          end

          since = page["nextSince"].to_i
          # Bump the cursor directly: it's derived sync state, and a legacy
          # source still missing its instance_id would otherwise fail model
          # validation. Clearing the error treats a past failure as transient.
          source.this.update(cursor: since.to_s, last_synced_at: Time.now,
                             last_error_id: nil)
          break unless page["hasMore"] && entries.any?
        end

        Rewind.logger.info(
          "[sync] source #{source.id}: #{tally_line(tally)} in " \
          "#{Rewind.format_duration(Rewind.clock - started)}"
        )
      rescue StandardError => error
        ErrorLog.record(error, context: {
                          "component" => "sync",
                          "source_id" => source.id,
                          "user_id" => source.user_id
                        })
        record_error(source, error.message)
        raise # let run_once / sync_one keep their existing logging and abort
      end

      # "3 written, 1 removed, 40 unchanged" — what a sync did, by outcome.
      def self.tally_line(tally)
        return "no changes" if tally.empty?

        tally.map {|outcome, count| "#{count} #{outcome}" }.join(", ")
      end

      # Forget what was imported from these sources: delete their Jellyfin
      # plays and clear their cursors, so the next sync re-imports the full
      # history from the plugin. Besides the source's own plays, this takes the
      # user's orphaned plays from the same server (the old webhook's, or a
      # deleted connection's); another account's source on that server keeps
      # its plays. Returns how many plays were removed; the caller rebuilds
      # streaks.
      def self.reset(sources)
        removed = 0
        Rewind::Play.skip_activity_tracking do
          sources.each do |source|
            plays = Rewind::Play.where(user_id: source.user_id,
                                       source: source.type)
            owned = {source_id: source.id}
            if source.instance_id
              orphaned = {source_id: nil, instance_id: source.instance_id}
              owned = Sequel.|(owned, orphaned)
            end
            plays = plays.where(owned)
            removed += plays.delete
            source.this.update(cursor: nil)
            source.refresh # callers sync these objects next
          end
        end
        removed
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

      # Plays dedupe on (user, instance, event id), and the unique index skips
      # rows without an instance, so never write before knowing it. Sources
      # connected through Settings carry it already; this covers older ones.
      def self.adopt_instance_id(source, adapter)
        return if source.instance_id

        instance_id = adapter.server_id
        unless instance_id
          raise Rewind::Error,
                "Could not read the Jellyfin server id"
        end

        source.this.update(instance_id:)
        source.instance_id = instance_id
      end

      # Keep the source's Jellyfin username current (it can be renamed), so
      # Settings shows who each connection is. Best effort: when the name can't
      # be read the stored one stays, and the sync goes on.
      def self.refresh_user_name(source, adapter)
        name = adapter.user_name
        return if name.nil? || name == source.external_user_name

        source.this.update(external_user_name: name)
        source.external_user_name = name
      end

      # The plays-table key for a plugin history record. The record id is
      # stable for the life of the playback session, so it's the play's
      # identity across every change the feed reports.
      def self.event_id(entry)
        "rewind:#{entry['id']}"
      end

      # Applies one changes-feed entry as its own committed write:
      #
      # - deleted, or not (or no longer) a scrobble: remove the play recorded
      #   for it, if any (:removed / :ignored).
      # - a scrobble already recorded: nothing to do (:unchanged). Its played_at
      #   is the session's start, which never moves, so the frozen local_date
      #   stays right.
      # - a new scrobble: resolve the item and record it (:written), or
      #   :skipped when the item can't be matched.
      #
      # Returns :deferred when SQLite was too busy to take the write. Any other
      # error propagates (the cursor is held and the page retried).
      def self.record_entry(source, adapter, entry)
        key = event_id(entry)
        existing = Rewind::Play.where(user_id: source.user_id,
                                      instance_id: source.instance_id,
                                      source_event_id: key).first

        unless entry["scrobbled"] && !entry["deleted"]
          return :ignored unless existing

          existing.destroy
          return :removed
        end
        return :unchanged if existing

        item = adapter.resolve_entry(entry)
        unless item
          skipped(source, entry)
          return :skipped
        end

        Rewind::Play.create(
          user_id: source.user_id,
          item_id: item.id,
          source_id: source.id,
          instance_id: source.instance_id,
          source: source.type,
          source_event_id: key,
          played_at: Time.parse(entry["startedAt"]).utc
        )
        :written
      rescue Sequel::UniqueConstraintViolation
        :unchanged
      rescue Sequel::DatabaseError => error
        raise unless database_locked?(error)

        Rewind.logger.warn(
          "[sync] source #{source.id}: deferred #{key} — database locked"
        )
        :deferred
      end

      # A scrobble whose item couldn't be matched is dropped (the cursor moves
      # on), so surface it on the errors page rather than only in the log.
      def self.skipped(source, entry)
        ErrorLog.record(
          Rewind::Error.new(
            "Unmatched play: #{entry['itemType']} #{entry['name'].inspect}"
          ),
          context: {
            "component" => "sync",
            "source_id" => source.id,
            "user_id" => source.user_id,
            "play_id" => entry["id"],
            "item_id" => entry["itemId"]
          }
        )
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
