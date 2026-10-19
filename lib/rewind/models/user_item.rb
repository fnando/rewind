# frozen_string_literal: true

module Rewind
  class UserItem < Sequel::Model
    many_to_one :user

    def validate
      super
      return unless !rating.nil? && !(1..5).cover?(rating)

      errors.add(:rating,
                 "must be between 1 and 5")
    end
  end
end
