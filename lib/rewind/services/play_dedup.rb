# frozen_string_literal: true

module Rewind
  module Services
    # Removes Jellyfin plays that are the same watch/listen recorded more than
    # once. Two shapes, both idempotent and safe to re-run:
    #
    #   1. Windowed video: a movie/episode/music video re-logged tick-by-tick
    #      as Jellyfin advanced its LastPlayedDate while it played, so each
    #      pull (and the webhook's completion) landed under a new key. The
    #      forward guard stops new ones; this sweeps the backlog.
    #   2. Start/stop pair: an audio track logged by the pull at its start and
    #      by the webhook at its stop, under different keys.
    #
    # Destroys go through the model so Play's hooks realign user_day_activity.
    module PlayDedup
      MARGIN = 120 # seconds, absorbs pauses between a track's start and stop
      FALLBACK = 600 # seconds, when a track's length is unknown

      # Removes every duplicate and returns how many it destroyed.
      def self.run
        collapse_windowed_video_plays + collapse_start_stop_pairs
      end

      # Collapse a video re-logged while it played. Plays of the same (user,
      # item, instance) within one runtime window are the same watch — keep the
      # earliest, drop the rest. Audio is excluded: it settles its date once,
      # and short tracks are legitimately replayed back-to-back.
      def self.collapse_windowed_video_plays
        item_ids = Item.where(media_type: Play::WATCH_DEDUP_MEDIA_TYPES)
                       .select_map(:id)
        return 0 if item_ids.empty?

        windows = video_windows(item_ids)
        plays = Play.where(source: "jellyfin", item_id: item_ids)
                    .exclude(played_at: nil)
                    .order(:played_at, :id)
                    .all

        duplicates = plays
                     .group_by {|p| [p.user_id, p.item_id, p.instance_id] }
                     .flat_map do |(_, item_id, _), group|
                       windowed_extras(group, windows[item_id] || FALLBACK)
                     end
        duplicates.each(&:destroy)
        duplicates.size
      end

      # The non-anchor plays in a group: walking oldest-first, each play within
      # +window+ seconds of its cluster's anchor is a duplicate; one beyond it
      # starts a new cluster (a genuine re-watch).
      def self.windowed_extras(group, window)
        anchor = nil
        group.each_with_object([]) do |play, extras|
          if anchor && (play.played_at - anchor.played_at) <= window
            extras << play
          else
            anchor = play
          end
        end
      end

      # item_id -> runtime-based dedup window (seconds) for each video item.
      def self.video_windows(item_ids)
        Item.where(id: item_ids).each_with_object({}) do |item, result|
          result[item.id] = Play.watch_window(item)
        end
      end

      # Pairs each audio pull play (source_id set) with the webhook play
      # (source_id null) that re-recorded the same completion — same user +
      # track, within one runtime after it — and destroys the webhook duplicate.
      # Webhook-only plays (the pull missed them) have no partner, left alone.
      def self.collapse_start_stop_pairs
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
