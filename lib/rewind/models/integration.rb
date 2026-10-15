# frozen_string_literal: true

module Rewind
  class Integration < Sequel::Model
    many_to_one :user
    one_to_many :plays

    KINDS = %w[jellyfin].freeze

    # Plaintext token, only present right after generate/rotate. Never
    # persisted; only the HMAC digest is stored, so a database leak exposes no
    # usable token.
    attr_accessor :plain_token

    def token=(plain)
      self.plain_token = plain
      self.token_digest = plain.nil? ? nil : self.class.digest_token(plain)
    end

    # Available only on the in-memory object that generated it (create/rotate).
    def token
      plain_token
    end

    def self.digest_token(plain)
      salt = Rewind.config.salt
      if salt.to_s.empty?
        raise Rewind::Error,
              "REWIND_SALT must be set to hash integration tokens"
      end

      OpenSSL::HMAC.hexdigest("SHA256", salt, plain.to_s)
    end

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
      self.token = self.class.generate_token
      save_changes
      plain_token
    end

    def self.generate_token
      SecureRandom.urlsafe_base64(32)
    end

    def validate
      super
      errors.add(:kind, "must be jellyfin") unless KINDS.include?(kind)
      errors.add(:label, "is required") if label.to_s.strip.empty?
      errors.add(:token, "is required") if token_digest.to_s.strip.empty?
      return unless kind == "jellyfin" && external_user_id.to_s.strip.empty?

      errors.add(:external_user_id, "is required for Jellyfin integrations")
    end
  end
end
