# frozen_string_literal: true

module Rewind
  module Services
    # Collapses a duplicate (synthetic) music artist onto its real MusicBrainz
    # twin, preserving every play and rating. Driven by `rewind artists:merge`.
    #
    # Why this exists: an untagged library mints deterministic *synthetic* ids
    # (Services::MusicBrainz), so the same artist/album can be stored twice —
    # once synthetic, once mbid — each holding a slice of the discography and
    # its plays. Re-tagging in Jellyfin can also change a file's Jellyfin id, so
    # two can't be matched by jellyfin_id; we match by name instead.
    #
    # A run does two things under the target artist:
    #   1. Moves the source artist's albums/tracks onto it (when from != to),
    #      pairing each album/track to its twin by normalized title.
    #   2. De-duplicates the target's own albums — collapses a synthetic album
    #      onto an mbid album of the same title. This handles the album whose
    #      mbid twin wasn't synced yet when an earlier artist merge ran, so it
    #      got re-parented rather than merged: sync, then run the merge again
    #      (pass the same id for --from and --to to only de-duplicate).
    #
    # Pairing is 1:1 (a target twin is consumed once). Matched tracks have their
    # plays repointed onto the twin and are then deleted; unmatched children (no
    # twin, not in MusicBrainz) are re-parented and kept, so no play is ever
    # lost. Every collapse is written to `item_merges` so a later untagged play
    # that would re-mint the synthetic id routes to the mbid item instead
    # (MusicBrainz#canonical) rather than resurrecting the split.
    #
    # Mutation rules (learned from PlayDedup / migration 018):
    #   * Plays and user_day_activity are touched with raw datasets (no model
    #     hooks fire), so activity is adjusted by hand. Repointing a play
    #     track->track keeps it music/same-day, so the bucket is unchanged.
    #     Only dropped duplicates decrement. The dedup key is played_at, NOT
    #     source_event_id (which embeds the old track's Jellyfin id, so twins
    #     never share it).
    #   * Items, user_items and item_merges go through the models/datasets with
    #     read-modify-write on metadata JSON, so mirrors (parent pointers, the
    #     "artist" display string) stay consistent.
    #
    # An item is only deleted after its plays are repointed/dropped (plays'
    # item_id is ON DELETE CASCADE — a stray play would go with it), guarded by
    # an assertion. The whole merge is one transaction: all-or-nothing. Not
    # idempotent — item_merges.from_external_id is unique, so a re-run fails
    # closed. Run with sync paused so it doesn't fight for the SQLite writer.
    class MusicMerge
      class Error < StandardError; end

      Summary = Struct.new(
        :albums_merged, :albums_reparented,
        :tracks_merged, :tracks_reparented,
        :plays_repointed, :plays_dropped,
        :user_items_migrated, :rating_conflicts,
        :map_entries, :drift,
        keyword_init: true
      )

      def initialize(from:, to:)
        @from = from
        @to = to
        @emit = ->(_message) { }
        @affected_user_ids = Set.new
        @summary = Summary.new(
          albums_merged: 0, albums_reparented: 0,
          tracks_merged: 0, tracks_reparented: 0,
          plays_repointed: 0, plays_dropped: 0,
          user_items_migrated: 0, rating_conflicts: 0,
          map_entries: 0, drift: []
        )
      end

      # Runs the merge, yielding progress strings. Returns the Summary.
      def run(&block)
        @emit = block if block
        validate!

        Rewind.db.transaction do
          merge_artist_into(@from, @to) unless @from.id == @to.id
          dedupe_albums(@to)
          albums_of(@to).each {|album| dedupe_tracks(album) }
        end
        emit summary_message

        verify_affected_users
        @summary
      end

      private def summary_message
        if @from.id == @to.id
          "de-duplicated #{@to.title.inspect}"
        else
          "merged #{@from.title.inspect} into #{@to.title.inspect}"
        end
      end

      private def validate!
        raise Error, "both items must exist" unless @from && @to
        return if @from.media_type == "artist" && @to.media_type == "artist"

        raise Error, "both --from and --to must be artists " \
                     "(got #{@from.media_type}/#{@to.media_type})"
      end

      # Move every album/track under `from` onto `to`, then drop `from`.
      private def merge_artist_into(from, to)
        record_merge(from.external_id, to.external_id)
        album_pairs, unmatched = pair_by_title(albums_of(from), albums_of(to))
        album_pairs.each {|source, target| collapse_album(source, target, to) }
        unmatched.each {|album| reparent_album(album, artist: to) }
        migrate_user_items(from.rating_key, to.rating_key)
        assert_no_plays!(from)
        delete_item(from)
      end

      # Collapse synthetic albums onto their mbid twin of the same title, then
      # (per album) synthetic tracks onto their mbid twin. A play finally lands
      # on the real track when its album's discography has been backfilled.
      private def dedupe_albums(artist)
        dedupe_by_title(albums_of(artist)) do |source, target|
          collapse_album(source, target, artist)
        end
      end

      private def dedupe_tracks(album)
        dedupe_by_title(tracks_of(album)) do |source, target|
          merge_track(source, target)
        end
      end

      # Collapse synthetic items onto an mbid sibling of the same title. Acts
      # only on an unambiguous group — exactly one mbid item and one or more
      # synthetic ones sharing a normalized title — so two distinct mbid
      # releases that happen to share a title are never merged.
      private def dedupe_by_title(items)
        items.group_by {|item| normalize(item.title) }.each_value do |group|
          next if group.size < 2

          synthetics, targets = group.partition {|item| synthetic?(item) }
          next unless targets.size == 1 && synthetics.any?

          synthetics.each {|source| yield(source, targets.first) }
        end
      end

      # --- Pairing ---------------------------------------------------------

      private def pair_tracks(source_album, target_album)
        remaining = tracks_of(target_album)
        matched = []
        unmatched = []
        tracks_of(source_album).each do |source|
          key = normalize(source.title)
          candidates = remaining.select {|t| normalize(t.title) == key }
          # Prefer the twin with the same track number when a title repeats.
          target = candidates.find do |t|
            t.track_number == source.track_number
          end || candidates.first
          if target
            remaining.delete(target)
            matched << [source, target]
          else
            unmatched << source
          end
        end
        [matched, unmatched]
      end

      # Match each source to a target of equal normalized title, consuming the
      # target so a merge stays 1:1. Returns matched pairs + unmatched sources.
      private def pair_by_title(sources, targets)
        remaining = targets.dup
        matched = []
        unmatched = []
        sources.each do |source|
          idx = remaining.index do |t|
            normalize(t.title) == normalize(source.title)
          end
          if idx
            matched << [source, remaining.delete_at(idx)]
          else
            unmatched << source
          end
        end
        [matched, unmatched]
      end

      private def albums_of(artist)
        Item.where(media_type: "album",
                   parent_external_id: artist.external_id).all
      end

      private def tracks_of(album)
        Item.where(media_type: "track",
                   parent_external_id: album.external_id).all
      end

      private def normalize(title)
        title.to_s.downcase.strip
      end

      private def synthetic?(item)
        item.external_id.to_s.start_with?("mbid:synthetic:")
      end

      # --- Mutations -------------------------------------------------------

      private def collapse_album(source_album, target_album, artist)
        track_pairs, unmatched_tracks = pair_tracks(source_album, target_album)
        track_pairs.each {|source, target| merge_track(source, target) }
        unmatched_tracks.each do |track|
          reparent_track(track, target_album, artist:)
        end

        migrate_user_items(source_album.rating_key, target_album.rating_key)
        record_merge(source_album.external_id, target_album.external_id)
        assert_no_plays!(source_album)
        delete_item(source_album)
        @summary.albums_merged += 1
        emit "  album #{source_album.title.inspect} -> " \
             "#{target_album.title.inspect} (#{track_pairs.size} merged, " \
             "#{unmatched_tracks.size} kept)"
      end

      private def merge_track(source, target)
        record_merge(source.external_id, target.external_id)
        migrate_user_items(source.rating_key, target.rating_key)
        repoint_plays(source, target)
        assert_no_plays!(source)
        delete_item(source)
        @summary.tracks_merged += 1
      end

      # Move source's plays onto target, dropping any that target already has
      # (same user + played_at, or same unique-index key). Repoints stay
      # music/same-day → activity unchanged; drops decrement their bucket.
      private def repoint_plays(source, target)
        by_time, by_event = existing_play_keys(target)
        repoint_ids = []

        source_plays(source).each do |play|
          @affected_user_ids << play[:user_id]
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
        @summary.plays_repointed += repoint_ids.size
      end

      private def existing_play_keys(target)
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

      private def source_plays(source)
        Rewind.db[:plays].where(item_id: source.id)
              .select(:id, :user_id, :played_at, :instance_id,
                      :source_event_id, :local_date).all
      end

      private def time_key_for(play)
        [play[:user_id], play[:played_at]] if play[:played_at]
      end

      private def event_key_for(play)
        return unless play[:instance_id] && play[:source_event_id]

        [play[:user_id], play[:instance_id], play[:source_event_id]]
      end

      private def drop_play(play)
        Rewind.db[:plays].where(id: play[:id]).delete
        @summary.plays_dropped += 1
        # Undated plays never contributed to a day bucket.
        return unless play[:local_date]

        scope = Rewind.db[:user_day_activity].where(
          user_id: play[:user_id], media_group: "music", day: play[:local_date]
        )
        scope.update(play_count: Sequel[:play_count] - 1)
        scope.where { play_count <= 0 }.delete
      end

      # Keep an unmatched track (no twin) under the target album + artist.
      private def reparent_track(track, target_album, artist:)
        track.update(
          parent_external_id: target_album.external_id,
          metadata: track.metadata.merge(
            "album_external_id" => target_album.external_id,
            "artist_external_id" => artist.external_id,
            "artist" => artist.title
          )
        )
        @summary.tracks_reparented += 1
      end

      # Keep an unmatched album (no mbid twin) under the target artist, fixing
      # its and its tracks' artist mirror so pages show the real artist name.
      private def reparent_album(album, artist:)
        album.update(
          parent_external_id: artist.external_id,
          metadata: album.metadata.merge(
            "artist_external_id" => artist.external_id,
            "artist" => artist.title
          )
        )
        tracks_of(album).each do |track|
          track.update(
            metadata: track.metadata.merge(
              "artist_external_id" => artist.external_id,
              "artist" => artist.title
            )
          )
        end
        @summary.albums_reparented += 1
        emit "  album #{album.title.inspect} kept (no mbid twin), " \
             "re-parented under #{artist.title.inspect}"
      end

      private def record_merge(from_ext, to_ext)
        return if from_ext == to_ext

        Rewind.db[:item_merges].insert(
          from_external_id: from_ext, to_external_id: to_ext,
          created_at: Time.now
        )
        @summary.map_entries += 1
      end

      # Move ratings/reviews from one rating_key to another, merging field-by-
      # field when both sides exist (unique on user_id + item_key).
      private def migrate_user_items(old_key, new_key)
        return if old_key == new_key

        UserItem.where(item_key: old_key).each do |source|
          target = UserItem.where(user_id: source.user_id,
                                  item_key: new_key).first
          if target.nil?
            source.update(item_key: new_key)
          else
            @summary.rating_conflicts += 1 if merge_user_item_fields(source,
                                                                     target)
            source.destroy
          end
          @summary.user_items_migrated += 1
        end
      end

      # Fold source into the surviving target row: prefer target on a rating
      # clash, carry the review (with its timestamps) only when target has none.
      # Returns whether two differing ratings collided, so the caller can warn.
      private def merge_user_item_fields(source, target)
        attrs = {}
        conflict = false
        both_rated = !target.rating.nil? && !source.rating.nil?
        if target.rating.nil? && !source.rating.nil?
          attrs[:rating] = source.rating
        elsif both_rated && target.rating != source.rating
          conflict = true
          emit "  rating conflict on #{target.item_key}: " \
               "kept #{target.rating}, dropped #{source.rating}"
        end
        if blank?(target.review) && !blank?(source.review)
          attrs[:review] = source.review
          attrs[:review_created_at] = source.review_created_at
          attrs[:review_updated_at] = source.review_updated_at
        end
        target.update(attrs) unless attrs.empty?
        conflict
      end

      private def assert_no_plays!(item)
        return if Rewind.db[:plays].where(item_id: item.id).empty?

        raise Error, "refusing to delete #{item.media_type} #{item.id} " \
                     "(#{item.title.inspect}) — it still has plays"
      end

      private def delete_item(item)
        Rewind.db[:items].where(id: item.id).delete
      end

      # After commit, confirm the derived streak table still matches `plays` for
      # everyone we touched (repoints are activity-invariant, drops decrement —
      # so this should always be clean; it's a guard against an accounting bug).
      private def verify_affected_users
        @affected_user_ids.each do |uid|
          user = User[uid]
          next unless user

          drift = Streaks.verify(user)
          next if drift.empty?

          @summary.drift.concat(drift.map {|row| row.merge(user_id: uid) })
          emit "  WARNING streak drift for user #{uid}: #{drift.inspect}"
        end
      end

      private def blank?(value)
        value.to_s.strip.empty?
      end

      private def emit(message)
        @emit.call(message)
      end
    end
  end
end
