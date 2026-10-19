# frozen_string_literal: true

module Rewind
  # The timezone context a user was in at a moment in time — PST and PDT are
  # distinct entries (same name, different offset). A play references the entry
  # in effect when it happened, frozen forever, so moving zones never rewrites
  # history. See migration 016.
  class UserTimezoneEntry < Sequel::Model
    many_to_one :user
    one_to_many :plays

    # Resolves the entry + local calendar day for a user at a given instant.
    # The offset is taken at that exact instant, so DST is handled correctly and
    # the result is stable regardless of the user's current timezone. Returns
    # [entry, Date].
    def self.resolve(user, instant)
      name = user.timezone || "UTC"
      tz =
        begin
          TZInfo::Timezone.get(name)
        rescue TZInfo::InvalidTimezoneIdentifier
          name = "UTC"
          TZInfo::Timezone.get("UTC")
        end

      utc = instant.utc
      offset = tz.period_for(utc).observed_utc_offset
      [find_or_create_entry(user.id, name, offset), (utc + offset).to_date]
    end

    def self.find_or_create_entry(user_id, name, offset)
      where(user_id:, name:, offset:).first ||
        create(user_id:, name:, offset:)
    rescue Sequel::UniqueConstraintViolation
      # A concurrent writer created the same (user, name, offset); reuse it.
      where(user_id:, name:, offset:).first
    end
  end
end
