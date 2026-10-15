# frozen_string_literal: true

require "bcrypt"

module Rewind
  class User < Sequel::Model
    one_to_many :plays
    one_to_many :integrations
    one_to_many :user_items

    RATING_STYLES = %w[stars thumbs].freeze

    def before_validation
      self.rating_style ||= "stars"
      self.timezone ||= "UTC"
      self.must_change_password = false if must_change_password.nil?
      super
    end

    def password=(plain)
      self.password_digest = BCrypt::Password.create(plain)
    end

    def authenticate(plain)
      return false if password_digest.nil? || password_digest.empty?

      BCrypt::Password.new(password_digest) == plain
    rescue BCrypt::Errors::InvalidHash
      false
    end

    def validate
      super
      errors.add(:username, "is required") if username.to_s.strip.empty?
      if username && username !~ /\A[a-z0-9][a-z0-9_-]{0,30}\z/i
        errors.add(:username,
                   "must be url-safe")
      end
      unless RATING_STYLES.include?(rating_style)
        errors.add(:rating_style,
                   "must be stars or thumbs")
      end
      return if TZInfo::Timezone.all_identifiers.include?(timezone)

      errors.add(:timezone, "is not a valid IANA timezone")
    end
  end
end
