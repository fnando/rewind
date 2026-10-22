# frozen_string_literal: true

module Rewind
  module Services
    # One-time migration to the release-scoped identity scheme: album =
    # `mbid:release:<release>`, track = `mbid:rt:<release-track>`. It reads the
    # authoritative ids from the AudioMetadata plugin (per album) and matches DB
    # rows by their **Jellyfin id**, so a track stranded under an old
    # `mbid:rg:`/recording album is still found and moved.
    #
    # Re-keys IN PLACE (`UPDATE items SET external_id/parent`) so plays — which
    # reference items by pk, not external_id — stay attached. When the target id
    # is already taken (e.g. a newer sync minted it), the row is absorbed
    # into it: plays moved with played_at dedup + user_day_activity accounting,
    # ratings migrated, row deleted — the same accounting as PlayDedup /
    # MusicMerge / migration 018. Finally, albums left childless (`mbid:rg:`,
    # synthetic) are pruned; real `mbid:release:` discography rows are kept.
    #
    # Items the plugin doesn't know (stale/untagged Jellyfin id) or albums
    # without a release id are left untouched and counted as skipped — reconcile
    # those by name with `artists:merge`.
    class MusicRekey
      Summary = Struct.new(
        :albums_rekeyed, :tracks_rekeyed, :items_absorbed,
        :plays_moved, :plays_dropped, :albums_pruned, :skipped, :drift,
        keyword_init: true
      )

      def initialize(client:)
        @client = client
        @emit = ->(_message) { }
        @affected_user_ids = Set.new
        @summary = Summary.new(
          albums_rekeyed: 0, tracks_rekeyed: 0, items_absorbed: 0,
          plays_moved: 0, plays_dropped: 0, albums_pruned: 0, skipped: 0,
          drift: []
        )
      end

      def run(&block)
        @emit = block if block

        album_jellyfin_ids.each {|jellyfin_id| rekey_album(jellyfin_id) }
        @summary.albums_pruned = prune_childless_albums
        verify_affected_users
        @summary
      end

      # Distinct Jellyfin album ids we currently store an album for.
      private def album_jellyfin_ids
        Rewind::Item.where(media_type: "album").exclude(jellyfin_id: nil)
                    .distinct.select_map(:jellyfin_id)
      end

      private def rekey_album(jellyfin_id)
        meta = @client.album_metadata(jellyfin_id)
        release = presence(meta[:release])
        return @summary.skipped += 1 unless release

        album_ext = "mbid:release:#{release}"
        album = rekey_item(albums_for(jellyfin_id), album_ext)
        return unless album

        @summary.albums_rekeyed += 1
        emit "album #{album.title.inspect} -> #{album_ext}"

        artist_ext = album.parent_external_id
        artist_title = Rewind::Item.where(external_id: artist_ext).get(:title)
        Array(meta[:tracks]).each do |entry|
          rekey_track(entry, album_ext:, artist_ext:, artist_title:)
        end
      end

      private def albums_for(jellyfin_id)
        Rewind::Item.where(media_type: "album", jellyfin_id:).all
      end

      private def rekey_track(entry, album_ext:, artist_ext:, artist_title:)
        release_track = presence(entry[:release_track])
        item_id = presence(entry[:item_id])
        return unless release_track && item_id

        tracks = Rewind::Item.where(media_type: "track",
                                    jellyfin_id: item_id).all
        return if tracks.empty?

        rekey_item(
          tracks, "mbid:rt:#{release_track}",
          parent_external_id: album_ext,
          metadata_overrides: {
            "album_external_id" => album_ext,
            "artist_external_id" => artist_ext,
            "artist" => artist_title
          }.compact
        )
        @summary.tracks_rekeyed += 1
      end

      # Consolidate every `items` row (same media_type) onto `new_ext`: re-key
      # in place (or reuse an existing row already at new_ext) and absorb the
      # rest into it. Applies the parent/metadata updates to the survivor and
      # returns it. nil when there's nothing to do.
      private def rekey_item(items, new_ext, parent_external_id: nil,
                             metadata_overrides: nil)
        items = Array(items).uniq(&:id)
        return if items.empty?

        media_type = items.first.media_type
        target = items.find {|item| item.external_id == new_ext } ||
                 Rewind::Item.where(media_type:, external_id: new_ext).first
        rekey_in_place = target.nil?
        target ||= items.first

        apply_updates(target, new_ext, rekey_in_place, parent_external_id,
                      metadata_overrides)

        (items - [target]).each do |item|
          absorb(item, target)
          @summary.items_absorbed += 1
        end
        target
      end

      private def apply_updates(target, new_ext, rekey_in_place,
                                parent_external_id, metadata_overrides)
        attrs = {}
        if rekey_in_place && target.external_id != new_ext
          attrs[:external_id] = new_ext
        end
        attrs[:parent_external_id] = parent_external_id if parent_external_id
        if metadata_overrides && !metadata_overrides.empty?
          attrs[:metadata] = target.metadata.merge(metadata_overrides)
        end
        target.update(attrs) unless attrs.empty?
      end

      # Move source's plays + ratings onto target and delete source.
      private def absorb(source, target)
        migrate_user_items(source.rating_key, target.rating_key)
        repoint_plays(source, target)
        assert_no_plays!(source)
        Rewind.db[:items].where(id: source.id).delete
      end

      # --- Play move (raw SQL, manual activity accounting) -----------------

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
        @summary.plays_moved += repoint_ids.size
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
        return unless play[:local_date]

        scope = Rewind.db[:user_day_activity].where(
          user_id: play[:user_id], media_group: "music", day: play[:local_date]
        )
        scope.update(play_count: Sequel[:play_count] - 1)
        scope.where { play_count <= 0 }.delete
      end

      # --- user_items + cleanup --------------------------------------------

      private def migrate_user_items(old_key, new_key)
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

      private def merge_user_item_fields(source, target)
        attrs = {}
        if target.rating.nil? && !source.rating.nil?
          attrs[:rating] =
            source.rating
        end
        if blank?(target.review) && !blank?(source.review)
          attrs[:review] = source.review
          attrs[:review_created_at] = source.review_created_at
          attrs[:review_updated_at] = source.review_updated_at
        end
        target.update(attrs) unless attrs.empty?
      end

      # Drop albums left with no tracks that aren't release-keyed (stale
      # mbid:rg:/synthetic leftovers). Real mbid:release: discography rows stay
      # even when we never created their tracks. Returns the count removed.
      private def prune_childless_albums
        parented = Rewind::Item.where(media_type: "track")
                               .exclude(parent_external_id: nil)
                               .select(:parent_external_id)
        Rewind::Item.where(media_type: "album")
                    .exclude(external_id: parented)
                    .exclude(Sequel.like(:external_id, "mbid:release:%"))
                    .delete
      end

      private def verify_affected_users
        @affected_user_ids.each do |uid|
          user = Rewind::User[uid]
          next unless user

          drift = Streaks.verify(user)
          next if drift.empty?

          @summary.drift.concat(drift.map {|row| row.merge(user_id: uid) })
          emit "  WARNING streak drift for user #{uid}: #{drift.inspect}"
        end
      end

      private def assert_no_plays!(item)
        return if Rewind.db[:plays].where(item_id: item.id).empty?

        raise "refusing to delete item #{item.id} (#{item.title.inspect}) — " \
              "it still has plays"
      end

      private def blank?(value)
        value.to_s.strip.empty?
      end

      private def presence(value)
        str = value.to_s.strip
        str.empty? ? nil : str
      end

      private def emit(message)
        @emit.call(message)
      end
    end
  end
end
