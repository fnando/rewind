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

        join(:items, id: :item_id)
          .where(Sequel[:items][:media_type] => type.to_s)
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
