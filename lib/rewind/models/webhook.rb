# frozen_string_literal: true

require "digest"
require "securerandom"

module Rewind
  # An admin-minted inbound webhook secret. We store only sha256(salt + secret),
  # so the raw secret is revealed once (at mint/rotate) and never again. See
  # migration 017 and routes/webhooks.rb.
  class Webhook < Sequel::Model
    # Creates a webhook and returns [record, raw_secret]. The caller must show
    # the secret to the admin now — it can't be recovered later.
    def self.mint(name: nil)
      secret = new_secret
      salt = SecureRandom.hex(16)
      record = create(name:, salt:, token_digest: digest(salt, secret))
      [record, secret]
    end

    # The enabled webhook whose stored digest matches this secret, or nil.
    # Compared in constant time against every candidate (N is tiny).
    def self.authenticate(secret)
      return if secret.to_s.empty?

      where(enabled: true).all.find do |webhook|
        Rack::Utils.secure_compare(webhook.token_digest,
                                   digest(webhook.salt, secret))
      end
    end

    def self.digest(salt, secret)
      Digest::SHA256.hexdigest("#{salt}#{secret}")
    end

    def self.new_secret
      SecureRandom.urlsafe_base64(32)
    end

    # Replaces the secret (new salt + digest), returning the new raw secret.
    def rotate!
      secret = self.class.new_secret
      self.salt = SecureRandom.hex(16)
      self.token_digest = self.class.digest(salt, secret)
      save
      secret
    end
  end
end
