# frozen_string_literal: true

require "bcrypt"

module Rewind
  class User < Sequel::Model
    one_to_many :plays
    one_to_many :sources
    one_to_many :user_items

    RATING_STYLES = %w[stars thumbs].freeze

    # The instance admin — the only role today. Gates the error log page.
    def admin?
      admin == true
    end

    def before_validation
      self.rating_style ||= "stars"
      self.timezone ||= "UTC"
      self.must_change_password = false if must_change_password.nil?
      super
    end

    # The UTC instant for a wall-clock time typed in this user's timezone, from
    # a datetime-local value ("2026-11-09T11:21", seconds optional). nil when
    # it isn't one. A time skipped by a DST jump rolls forward an hour; one
    # repeated by a DST fall-back reads as the first (daylight) occurrence.
    def local_time_to_utc(value)
      match = value.to_s.strip.match(
        /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?\z/
      )
      return unless match

      parts = match.captures.map(&:to_i)
      Time.utc(*parts) # validates the calendar date and clock time
      zone = TZInfo::Timezone.get(timezone || "UTC")
      begin
        zone.local_time(*parts, 0, true).utc
      rescue TZInfo::PeriodNotFound
        (zone.local_time(*parts[0, 3], parts[3] + 1, *parts[4..], 0, true)).utc
      end
    rescue ArgumentError, TZInfo::InvalidTimezoneIdentifier
      nil
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
