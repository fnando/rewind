# frozen_string_literal: true

module Rewind
  # A single user's claim on a Jellyfin user id for one allowlisted instance.
  # Incoming events are routed to this user when the payload's ServerUrl matches
  # the webhook and its UserId matches external_user_id.
  class Integration < Sequel::Model
    many_to_one :user
    many_to_one :webhook
    one_to_many :plays

    def disabled?
      !disabled_at.nil?
    end

    def validate
      super
      errors.add(:user_id, "is required") if user_id.nil?
      errors.add(:webhook_id, "is required") if webhook_id.nil?
      return unless external_user_id.to_s.strip.empty?

      errors.add(:external_user_id, "is required")
    end
  end
end
