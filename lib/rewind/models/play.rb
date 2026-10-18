# frozen_string_literal: true

require_relative "../services/streaks"

module Rewind
  class Play < Sequel::Model
    plugin :dirty # exposes previous_changes for the activity hooks

    many_to_one :user
    many_to_one :item

    # NB: no `many_to_one :source` association — the `source` column already
    # holds the play's origin kind ("manual"/"jellyfin"/"trakt"). The owning
    # Source (connection) is referenced by the `source_id` column directly.
    SOURCES = %w[manual jellyfin trakt].freeze

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
