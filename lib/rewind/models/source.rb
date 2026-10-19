# frozen_string_literal: true

module Rewind
  # A user's connection to an external play source (currently Jellyfin). Holds
  # the per-user access token, encrypted at rest via attr_keyring, plus a sync
  # cursor so the background poller only fetches plays newer than last time.
  class Source < Sequel::Model
    include AttrKeyring.sequel

    plugin :validation_helpers

    attr_keyring Rewind.config.keyring, digest_salt: ""
    attr_encrypt :credentials, encoder: JSON

    many_to_one :user
    one_to_many :plays
    one_to_many :source_errors
    many_to_one :last_error, class: :"Rewind::SourceError", key: :last_error_id

    TYPES = %w[jellyfin].freeze

    def enabled?
      !!enabled
    end

    # The current, unresolved sync error, or nil when the last sync succeeded.
    def current_error
      last_error
    end

    # The most recent error ever recorded (resolved or not), for the
    # "See previous error" affordance once the current error is cleared.
    def latest_error
      source_errors_dataset.order(Sequel.desc(:created_at)).first
    end

    # Decrypted access token used to call the provider API.
    def access_token
      (credentials || {})["access_token"]
    end

    def url=(value)
      super(self.class.normalize_url(value))
    end

    def self.normalize_url(value)
      value.to_s.strip.sub(%r{/+\z}, "")
    end

    def validate
      super
      errors.add(:user_id, "is required") if user_id.nil?
      errors.add(:type, "must be jellyfin") unless TYPES.include?(type)
      errors.add(:url, "is required") if url.to_s.strip.empty?
      if external_user_id.to_s.strip.empty?
        errors.add(:external_user_id, "is required")
      end
      errors.add(:instance_id, "is required") if instance_id.to_s.strip.empty?
      errors.add(:credentials, "is required") if access_token.to_s.empty?
    end
  end
end
