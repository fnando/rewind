# frozen_string_literal: true

module Rewind
  module Services
    # Collapses Jellyfin plays recorded twice before the shared-key dedup: a
    # pull row at the track's start (LastPlayedDate, source_id set) and a
    # webhook row at its stop (source_id null), under different event ids. Pairs
    # each pull play with the webhook play that re-recorded the same completion
    # (same user + track, within one runtime after it) and destroys the webhook
    # duplicate. Webhook-only plays (the pull missed them) have no partner and
    # are left alone. Destroys go through the model so Play's hooks realign
    # user_day_activity. Idempotent — safe to re-run.
    module PlayDedup
      MARGIN = 120 # seconds, absorbs pauses between a track's start and stop
      FALLBACK = 600 # seconds, when a track's length is unknown

      # Removes the webhook duplicates and returns how many it destroyed.
      def self.run
        jellyfin = Play.where(source: "jellyfin").exclude(played_at: nil)
        pulls = jellyfin.exclude(source_id: nil).order(:played_at).all
        webhooks = jellyfin.where(source_id: nil).order(:played_at).all
        return 0 if pulls.empty? || webhooks.empty?

        runtimes = runtimes_for(pulls + webhooks)
        by_key = webhooks.group_by {|w| [w.user_id, w.item_id] }
        matched = {}
        duplicates = pulls.filter_map do |pull|
          window = (runtimes[pull.item_id] || FALLBACK) + MARGIN
          stop = (by_key[[pull.user_id, pull.item_id]] || []).find do |w|
            next if matched[w.id]

            (w.played_at - pull.played_at).between?(0, window)
          end
          next unless stop

          matched[stop.id] = true
          stop
        end

        duplicates.each(&:destroy)
        duplicates.size
      end

      # item_id -> playback length in seconds (track length, else runtime).
      def self.runtimes_for(plays)
        ids = plays.map(&:item_id).uniq
        Item.where(id: ids).each_with_object({}) do |item, result|
          ms = item.metadata["length_ms"]
          secs = ms ? ms.to_i / 1000 : item.runtime.to_i * 60
          result[item.id] = secs.positive? ? secs : FALLBACK
        end
      end
    end
  end
end
