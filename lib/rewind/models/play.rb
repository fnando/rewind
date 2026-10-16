# frozen_string_literal: true

module Rewind
  class Play < Sequel::Model
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
  end
end
