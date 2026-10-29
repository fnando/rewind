# frozen_string_literal: true

module Rewind
  class Play < Sequel::Model
    plugin :dirty # exposes previous_changes for the activity hooks

    many_to_one :user
    many_to_one :item
    many_to_one :user_timezone_entry

    # NB: no `many_to_one :source` association — the `source` column already
    # holds the play's origin kind ("manual"/"jellyfin"/"trakt"). The owning
    # Source (connection) is referenced by the `source_id` column directly.
    SOURCES = %w[manual jellyfin trakt].freeze

    # The media types that make up the "Music" grouping in History and Stats.
    # Tracks and music videos both play directly (albums/artists never do).
    MUSIC_MEDIA_TYPES = %w[track music_video].freeze

    # Video types whose LastPlayedDate Jellyfin advances WHILE they play, so a
    # per-minute pull (and the webhook's completion) would otherwise log the
    # same watch again and again under a new key. Audio is deliberately out: it
    # stays dateless until it settles once, and short tracks are legitimately
    # replayed back-to-back.
    WATCH_DEDUP_MEDIA_TYPES = %w[movie episode music_video].freeze

    # Seconds added to a video's runtime to absorb pauses, and the window used
    # when its runtime is unknown. A play of the same (user, item, instance)
    # within one runtime window is the same watch; the first writer wins. This
    # merges a genuine back-to-back replay too, the same trade-off PlayDedup
    # accepts — fine for video (you can't rewatch a 45-min episode in 45 min).
    WATCH_DEDUP_MARGIN = 120
    WATCH_DEDUP_FALLBACK = 600

    # The dedup window (seconds) for one item, from its runtime (minutes).
    def self.watch_window(item)
      seconds = item.runtime.to_i * 60
      base = seconds.positive? ? seconds : WATCH_DEDUP_FALLBACK
      base + WATCH_DEDUP_MARGIN
    end

    # Whether this watch is already recorded — any play of the same (user, item,
    # instance) within +window+ seconds of +played_at+. Undated candidates (nil
    # played_at) can't collide on time, so the guard is skipped.
    def self.watch_recorded?(user_id:, item_id:, instance_id:,
                             played_at:, window:)
      return false unless played_at

      !where(user_id:, item_id:, instance_id:)
        .where(played_at: (played_at - window)..(played_at + window))
        .empty?
    end

    # A completed Jellyfin play reaches us from both the pull sync and the
    # webhook. Both key their source_event_id on the same identity — the
    # track's Jellyfin id plus its LastPlayedDate (the webhook re-fetches that
    # date so it matches the pull) — so the (user_id, instance_id,
    # source_event_id) unique index collapses the two into one row. No time
    # window: a pause can't shift a stable id, and genuine re-listens carry a
    # distinct LastPlayedDate.
    dataset_module do
      def for_user(user)
        where(user_id: user.id)
      end

      def in_period(from, to)
        scope = self
        scope = scope.where { played_at >= from } if from
        scope = scope.where { played_at < to } if to
        scope
      end

      def for_media_type(type)
        return self if type.nil? || type.to_s == "all"

        types = type.is_a?(Array) ? type.map(&:to_s) : [type.to_s]
        join(:items, id: :item_id)
          .where(Sequel[:items][:media_type] => types)
          .select_all(:plays)
      end
    end

    def validate
      super
      errors.add(:source, "invalid") unless SOURCES.include?(source)
    end

    # Run a block (e.g. a bulk import) without the streak-activity hooks firing,
    # so thousands of rows don't each trigger an upsert. Callers must rebuild
    # the affected users afterwards with Services::Streaks.rebuild_user.
    def self.skip_activity_tracking
      previous = Thread.current[:rewind_skip_activity_tracking]
      Thread.current[:rewind_skip_activity_tracking] = true
      yield
    ensure
      Thread.current[:rewind_skip_activity_tracking] = previous
    end

    def self.skip_activity_tracking?
      Thread.current[:rewind_skip_activity_tracking] == true
    end

    # Freeze the timezone the play happened in, so history can group by local
    # day in SQL and a later timezone change never rewrites this play's day.
    # Runs for every insert path (manual, sync, import). Undated plays (no
    # played_at) carry a null entry/local_date and render as just "Watched".
    def before_create
      if played_at && user_timezone_entry_id.nil? && (user = owner)
        entry, date = UserTimezoneEntry.resolve(user, played_at)
        self.user_timezone_entry_id = entry.id
        self.local_date = date.iso8601
      end
      super
    end

    private def owner
      User.where(id: user_id).first
    end

    # Keep user_day_activity in sync. These run inside Sequel's save/destroy
    # transaction, so the derived table never drifts from `plays`. Plays are
    # immutable today, but after_update is handled defensively.
    def after_create
      super
      return if self.class.skip_activity_tracking?

      Services::Streaks.add_for_play(self)
    end

    def after_destroy
      super
      return if self.class.skip_activity_tracking?

      Services::Streaks.remove_for_play(self)
    end

    def after_update
      super
      return if self.class.skip_activity_tracking?
      return unless columns_changed_for_activity?

      previous = dup
      previous_changes.each {|col, (was, _now)| previous[col] = was }
      Services::Streaks.remove_for_play(previous)
      Services::Streaks.add_for_play(self)
    end

    private def columns_changed_for_activity?
      previous_changes.keys.intersect?(%i[played_at item_id user_id])
    end
  end
end
