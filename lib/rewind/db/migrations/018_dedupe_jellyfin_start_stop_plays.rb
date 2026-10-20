# frozen_string_literal: true

require "json"
require "time"

# Collapse Jellyfin plays that were recorded twice before the shared-key dedup:
# once by the pull sync at the track's LastPlayedDate (its start, source_id set)
# and once by the webhook at the PlaybackStop time (source_id null). They carry
# different source_event_ids — start vs stop — so the unique index never caught
# them. Pair each pull row with the webhook row that re-recorded the same
# completion (same user + track, within one runtime after it) and drop the
# webhook duplicate. Webhook-only plays (the pull missed them) have no pull
# partner and are left alone. We also decrement user_day_activity for each
# dropped play, since both copies had bumped its play_count. Runs raw SQL (the
# migrator doesn't load models); a no-op on fresh databases.
Sequel.migration do
  up do
    margin = 120 # seconds, absorbs pauses between a track's start and its stop
    fallback = 600 # seconds, when a track's length is unknown
    groups = {"movie" => "movie", "episode" => "series", "track" => "music"}

    as_time = ->(v) { v.is_a?(Time) ? v : Time.parse(v.to_s) }
    track_seconds = lambda do |metadata_json|
      next nil if metadata_json.nil? || metadata_json.empty?

      ms = JSON.parse(metadata_json)["length_ms"]
      ms && (ms.to_i / 1000)
    rescue JSON::ParserError
      nil
    end

    jellyfin = from(:plays).where(source: "jellyfin").exclude(played_at: nil)
    pulls = jellyfin.exclude(source_id: nil)
                    .select(:id, :user_id, :item_id, :played_at)
                    .order(:played_at).all
    webhooks = jellyfin.where(source_id: nil)
                       .select(:id, :user_id, :item_id, :played_at)
                       .order(:played_at).all
    next if pulls.empty? || webhooks.empty?

    item_ids = (pulls + webhooks).map {|p| p[:item_id] }.uniq
    runtime = {}
    from(:items).where(id: item_ids)
                .select(:id, :runtime, :metadata_json).each do |row|
      secs = track_seconds.call(row[:metadata_json])
      secs ||= row[:runtime].to_i * 60 if row[:runtime]
      runtime[row[:id]] = secs.to_i.positive? ? secs.to_i : fallback
    end

    webhooks_by_key = webhooks.group_by {|w| [w[:user_id], w[:item_id]] }
    matched = {}
    duplicate_ids = []
    pulls.each do |pull|
      window = (runtime[pull[:item_id]] || fallback) + margin
      start = as_time.call(pull[:played_at])
      key = [pull[:user_id], pull[:item_id]]
      stop = (webhooks_by_key[key] || []).find do |w|
        next if matched[w[:id]]

        (as_time.call(w[:played_at]) - start).between?(0, window)
      end
      next unless stop

      matched[stop[:id]] = true
      duplicate_ids << stop[:id]
    end
    next if duplicate_ids.empty?

    # Decrement the activity each dropped play had bumped, by its own
    # (user_id, media_group, local_date) bucket, then delete the plays.
    from(:plays).where(Sequel[:plays][:id] => duplicate_ids)
                .join(:items, id: :item_id)
                .select(Sequel[:plays][:user_id],
                        Sequel[:plays][:local_date],
                        Sequel[:items][:media_type]).each do |row|
      group = groups[row[:media_type]]
      next unless group && row[:local_date]

      from(:user_day_activity)
        .where(user_id: row[:user_id], media_group: group,
               day: row[:local_date])
        .update(play_count: Sequel[:play_count] - 1)
    end
    from(:user_day_activity).where { play_count <= 0 }.delete
    from(:plays).where(id: duplicate_ids).delete
  end

  down do
    # One-time data cleanup; the dropped duplicates can't be reconstructed.
  end
end
