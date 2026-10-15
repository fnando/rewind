# frozen_string_literal: true

module Rewind
  class UserItem < Sequel::Model
    many_to_one :user
    many_to_one :item

    def validate
      super
      errors.add(:rating, "must be between 1 and 5") if !rating.nil? && !(1..5).cover?(rating)
    end
  end
end
