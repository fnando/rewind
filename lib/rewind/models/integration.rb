# frozen_string_literal: true

module Rewind
  class Integration < Sequel::Model
    many_to_one :user
    one_to_many :plays

    KINDS = %w[jellyfin].freeze

    def settings
      return {} if settings_json.nil? || settings_json.empty?

      @settings ||= JSON.parse(settings_json)
    end

    def settings=(hash)
      @settings = nil
      self.settings_json = hash.nil? ? nil : JSON.generate(hash)
    end

    def disabled?
      !disabled_at.nil?
    end

    def rotate_token!
      update(token: self.class.generate_token)
    end

    def self.generate_token
      SecureRandom.urlsafe_base64(32)
    end

    def validate
      super
      errors.add(:kind, "must be jellyfin") unless KINDS.include?(kind)
      errors.add(:label, "is required") if label.to_s.strip.empty?
      errors.add(:token, "is required") if token.to_s.strip.empty?
      if kind == "jellyfin" && external_user_id.to_s.strip.empty?
        errors.add(:external_user_id, "is required for Jellyfin integrations")
      end
    end
  end
end
