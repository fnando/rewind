# frozen_string_literal: true

module Rewind
  module Services
    # Pulls recent plays from every enabled source into the plays table. Runs
    # once per `run_once`, or continuously on a background thread. Idempotent:
    # each source tracks a cursor, and plays dedupe on
    # (source_id, source_event_id).
    module Sync
      module_function def run_once
        Rewind::Source.where(enabled: true).each do |source|
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
      end

      module_function def sync_source(source)
        adapter = Sources.adapter_for(source)
        result = adapter.recent_plays(since: source.cursor)
        adopt_instance_id(source, result[:instance_id])

        if result[:plays].any? && source.instance_id.nil?
          Rewind.logger.error(
            "[sync] source #{source.id}: no Jellyfin ServerId in the " \
            "response; skipping #{result[:plays].size} plays to avoid dupes"
          )
          return
        end

        new_plays = result[:plays].count {|play| record_play(source, play) }
        # Bump the cursor directly: it's derived sync state, and a legacy source
        # still missing its instance_id would otherwise fail model validation.
        source.this.update(cursor: result[:cursor], last_synced_at: Time.now)
        Rewind.logger.info(
          "[sync] source #{source.id}: #{result[:plays].size} resolved, " \
          "#{new_plays} new"
        )
      end

      # Adopt the source's stable instance id (the ServerId that comes on every
      # Jellyfin payload) the first time we see it, and stamp any of this
      # instance's existing plays that predate the column. Keyed on instance_id,
      # plays then dedupe even after a source is deleted and re-added.
      module_function def adopt_instance_id(source, instance_id)
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

      module_function def record_play(source, play)
        Rewind::Play.create(
          user_id: source.user_id,
          item_id: play[:item_id],
          source_id: source.id,
          instance_id: source.instance_id,
          source: source.type,
          source_event_id: play[:source_event_id],
          played_at: play[:played_at]
        )
      rescue Sequel::UniqueConstraintViolation
        nil # already recorded on a previous sync
      end

      # Daemon thread that syncs forever. Started by `rewind run` only.
      module_function def start_thread(interval: Rewind.config.sync_interval)
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
