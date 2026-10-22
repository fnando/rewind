# frozen_string_literal: true

module Rewind
  module Services
    # The id ledger (jellyfin_seen) plus the recording-anchored re-tag healer.
    #
    # Why this exists: Jellyfin derives an item id from the file path, so
    # re-tagging a track in Picard (which renames/moves the file) gives the same
    # audio a brand-new id. The play we already recorded under the old id is
    # then stranded on the old row, and the id-based rekey can't reach it —
    # nothing links old id -> new id.
    #
    # The stable thread across a re-tag is the MusicBrainz **recording** id:
    # MusicBrainz keeps one recording across releases and Picard preserves
    # MUSICBRAINZ_TRACKID, so only the release / release-track change. We never
    # key identity on the recording (it's shared across editions — that
    # over-merges distinct albums); we use it only here, to recognise "this new
    # id is the same audio as a row we already have".
    #
    # `remember` records every resolved id (all media types) so the ledger is a
    # full history. `reconcile` runs when a *new* track id first appears: if its
    # recording matches a prior **played** row whose own file is gone (its id
    # 404s), that row is the re-tagged twin, so its plays/ratings are absorbed
    # onto the correctly-tagged row. The dead-id check is what keeps it safe:
    # owning the same recording on two live releases leaves both files present,
    # so neither 404s and nothing is merged. On any ambiguity we skip — a false
    # merge is never acceptable.
    #
    # Artists aren't archived: ensure_artist stores no Jellyfin id and artists
    # carry no plays, so there's nothing to heal.
    #
    # The absorb accounting mirrors the tested MusicRekey#absorb (plays moved
    # with played_at / source_event_id dedup + user_day_activity adjustment,
    # ratings migrated by rating_key). It's kept self-contained rather than
    # shared with MusicMerge/MusicRekey so this live-sync path stays surgical.
    module JellyfinArchive
      # True when we've already logged this id on this instance — so the caller
      # resolves the healer only on an id's first sighting, not every sync.
      def self.seen?(jellyfin_id, instance_id)
        return false unless presence(jellyfin_id)

        !Rewind.db[:jellyfin_seen]
               .where(instance_id: instance_id, jellyfin_id: jellyfin_id)
               .empty?
      end

      # Upsert the id -> item mapping (+ recording for tracks). Idempotent on
      # (instance_id, jellyfin_id); a no-op without an id. A later sighting with
      # no recording keeps the one we captured on first sight (coalesce), so the
      # cheap ids-only re-remembers on every sync never wipe it.
      def self.remember(item:, jellyfin_id:, media_type:, instance_id:,
                        recording_mbid: nil)
        return unless item && presence(jellyfin_id)

        Rewind.db[:jellyfin_seen]
              .insert_conflict(
                target: %i[instance_id jellyfin_id],
                update: {
                  item_id: item.id,
                  media_type: media_type,
                  recording_mbid: Sequel.function(
                    :coalesce,
                    Sequel[:excluded][:recording_mbid], :recording_mbid
                  ),
                  seen_at: Time.now
                }
              )
              .insert(
                jellyfin_id: jellyfin_id,
                item_id: item.id,
                media_type: media_type,
                recording_mbid: presence(recording_mbid),
                instance_id: instance_id,
                seen_at: Time.now
              )
      end

      # Heal a re-tag: if `target`'s recording matches a prior played row whose
      # own Jellyfin id is now dead, absorb that row into `target`. Returns the
      # absorbed item's id, or nil. Best-effort — never raises into sync.
      def self.reconcile(target:, recording_mbid:, instance_id:, user_id:,
                         client:)
        return unless target && presence(recording_mbid) &&
                      presence(instance_id)

        candidates = reconcile_candidates(target, recording_mbid, instance_id)
        return if candidates.empty?

        dead = candidates.select do |item|
          client.item_present?(user_id: user_id,
                               item_id: item.jellyfin_id) == false
        end
        decide(target, dead)
      rescue StandardError => error
        # A lock (or any hiccup) must never abort the sync batch; the id is
        # re-offered next run, so healing just retries.
        Rewind.logger.warn("[archive] reconcile failed: #{error.message}")
        nil
      end

      # Prior track rows sharing this recording on this instance, other than the
      # target, that hold something worth preserving (plays or a rating). An
      # unplayed cross-edition sibling shares the recording too — it's left
      # alone, never merged.
      def self.reconcile_candidates(target, recording_mbid, instance_id)
        item_ids = Rewind.db[:jellyfin_seen]
                         .where(recording_mbid: recording_mbid,
                                instance_id: instance_id, media_type: "track")
                         .exclude(item_id: target.id)
                         .distinct.select_map(:item_id)
        Rewind::Item.where(id: item_ids, media_type: "track")
                    .all.select {|item| worth_keeping?(item) }
      end

      def self.decide(target, dead)
        case dead.size
        when 0
          nil # nothing stranded, or every twin's file is still present
        when 1
          absorb(dead.first, target)
          dead.first.id
        else
          Rewind.logger.info(
            "[archive] ambiguous re-tag for item #{target.id}: " \
            "#{dead.size} dead twins — skipped"
          )
          nil
        end
      end

      def self.worth_keeping?(item)
        !Rewind.db[:plays].where(item_id: item.id).empty? ||
          !Rewind::UserItem.where(item_key: item.rating_key).empty?
      end

      # Move source's plays + ratings onto target, re-point the ledger, delete
      # source, then confirm the streak tables still match.
      def self.absorb(source, target)
        affected = Set.new
        migrate_user_items(source.rating_key, target.rating_key)
        repoint_plays(source, target, affected)
        Rewind.db[:jellyfin_seen].where(item_id: source.id)
              .update(item_id: target.id)
        assert_no_plays!(source)
        Rewind.db[:items].where(id: source.id).delete
        Rewind.logger.info(
          "[archive] re-tag healed: item #{source.id} " \
          "(#{source.title.inspect}) absorbed into #{target.id}"
        )
        verify_streaks(affected)
      end

      # --- Play move (raw SQL, manual activity accounting) -------------------

      def self.repoint_plays(source, target, affected)
        by_time, by_event = existing_play_keys(target)
        repoint_ids = []

        source_plays(source).each do |play|
          affected << play[:user_id]
          time_key = time_key_for(play)
          event_key = event_key_for(play)
          dup = (time_key && by_time.include?(time_key)) ||
                (event_key && by_event.include?(event_key))
          if dup
            drop_play(play)
          else
            repoint_ids << play[:id]
            by_time << time_key if time_key
            by_event << event_key if event_key
          end
        end

        return if repoint_ids.empty?

        Rewind.db[:plays].where(id: repoint_ids).update(item_id: target.id)
      end

      def self.existing_play_keys(target)
        by_time = Set.new
        by_event = Set.new
        Rewind.db[:plays].where(item_id: target.id)
              .select(:user_id, :played_at, :instance_id, :source_event_id)
              .each do |play|
          by_time << time_key_for(play) if time_key_for(play)
          by_event << event_key_for(play) if event_key_for(play)
        end
        [by_time, by_event]
      end

      def self.source_plays(source)
        Rewind.db[:plays].where(item_id: source.id)
              .select(:id, :user_id, :played_at, :instance_id,
                      :source_event_id, :local_date).all
      end

      def self.time_key_for(play)
        [play[:user_id], play[:played_at]] if play[:played_at]
      end

      def self.event_key_for(play)
        return unless play[:instance_id] && play[:source_event_id]

        [play[:user_id], play[:instance_id], play[:source_event_id]]
      end

      def self.drop_play(play)
        Rewind.db[:plays].where(id: play[:id]).delete
        return unless play[:local_date]

        scope = Rewind.db[:user_day_activity].where(
          user_id: play[:user_id], media_group: "music", day: play[:local_date]
        )
        scope.update(play_count: Sequel[:play_count] - 1)
        scope.where { play_count <= 0 }.delete
      end

      # --- user_items + guards ----------------------------------------------

      def self.migrate_user_items(old_key, new_key)
        return if old_key == new_key

        Rewind::UserItem.where(item_key: old_key).each do |source|
          target = Rewind::UserItem.where(user_id: source.user_id,
                                          item_key: new_key).first
          if target.nil?
            source.update(item_key: new_key)
          else
            merge_user_item_fields(source, target)
            source.destroy
          end
        end
      end

      def self.merge_user_item_fields(source, target)
        attrs = {}
        if target.rating.nil? && !source.rating.nil?
          attrs[:rating] = source.rating
        end
        if blank?(target.review) && !blank?(source.review)
          attrs[:review] = source.review
          attrs[:review_created_at] = source.review_created_at
          attrs[:review_updated_at] = source.review_updated_at
        end
        target.update(attrs) unless attrs.empty?
      end

      def self.assert_no_plays!(item)
        return if Rewind.db[:plays].where(item_id: item.id).empty?

        raise Rewind::Error, "refusing to delete item #{item.id} " \
                             "(#{item.title.inspect}) — it still has plays"
      end

      # Repoints are music/same-day so activity is invariant; drops decrement in
      # drop_play. This guards against an accounting slip, logging any drift.
      def self.verify_streaks(affected)
        affected.each do |uid|
          user = Rewind::User[uid]
          next unless user

          drift = Streaks.verify(user)
          next if drift.empty?

          Rewind.logger.warn(
            "[archive] streak drift for user #{uid}: #{drift.inspect}"
          )
        end
      end

      def self.blank?(value)
        value.to_s.strip.empty?
      end

      def self.presence(value)
        str = value.to_s.strip
        str.empty? ? nil : str
      end
    end
  end
end
