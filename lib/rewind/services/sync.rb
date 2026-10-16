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
          Rewind.logger.warn(
            "[sync] source #{source.id} unauthorized, disabling: " \
            "#{error.message}"
          )
          source.update(enabled: false)
        rescue StandardError => error
          Rewind.logger.warn("[sync] source #{source.id} failed: " \
                             "#{error.message}")
        end
      end

      module_function def sync_source(source)
        adapter = Sources.adapter_for(source)
        result = adapter.recent_plays(since: source.cursor)
        result[:plays].each {|play| record_play(source, play) }
        source.update(cursor: result[:cursor], last_synced_at: Time.now)
      end

      module_function def record_play(source, play)
        Rewind::Play.create(
          user_id: source.user_id,
          item_id: play[:item_id],
          source_id: source.id,
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
