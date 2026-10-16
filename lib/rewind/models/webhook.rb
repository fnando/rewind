# frozen_string_literal: true

module Rewind
  # An admin-allowlisted media server instance. Each row owns a webhook token
  # (shared by every user on that instance) and the server's URL, which incoming
  # payloads are matched against.
  class Webhook < Sequel::Model
    plugin :validation_helpers

    one_to_many :integrations

    TYPES = %w[jellyfin].freeze

    # Jellyfin webhook payload template. Pasted into Jellyfin's webhook
    # notification so incoming payloads carry the fields Rewind expects.
    JELLYFIN_TEMPLATE = <<~JSON
      {
        "NotificationType": "{{NotificationType}}",
        "Id": "{{Id}}",
        "UtcTimestamp": "{{UtcTimestamp}}",
        "ItemType": "{{ItemType}}",
        "ServerUrl": "{{ServerUrl}}",
        "UserId": "{{UserId}}",
        "PlaySessionId": "{{PlaySessionId}}",
        "PlayedToCompletion": "{{PlayedToCompletion}}",
        "PlaybackPositionTicks": "{{PlaybackPositionTicks}}",
        "RunTimeTicks": "{{RunTimeTicks}}",
        "Provider_tmdb": "{{Provider_tmdb}}",
        "Provider_imdb": "{{Provider_imdb}}",
        "SeriesProvider_tmdb": "{{SeriesProvider_tmdb}}",
        "SeriesProvider_imdb": "{{SeriesProvider_imdb}}",
        "SeasonNumber": "{{SeasonNumber00}}",
        "EpisodeNumber": "{{EpisodeNumber00}}",
        "Name": "{{Name}}",
        "Album": "{{Album}}",
        "Artist": "{{Artist}}",
        "Provider_MusicBrainzRecording": "{{Provider_musicbrainzrecording}}",
        "Provider_MusicBrainzReleaseGroup": "{{Provider_musicbrainzreleasegroup}}",
        "Provider_MusicBrainzAlbumArtist": "{{Provider_musicbrainzalbumartist}}",
        "Provider_MusicBrainzArtist": "{{Provider_musicbrainzartist}}"
      }
    JSON

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

    def url=(value)
      super(self.class.normalize_url(value))
    end

    def enabled?
      !!enabled
    end

    def rotate_token!
      self.token = self.class.generate_token
      save_changes
      plain_token
    end

    def self.generate_token
      SecureRandom.urlsafe_base64(32)
    end

    def self.digest_token(plain)
      salt = Rewind.config.salt
      if salt.to_s.empty?
        raise Rewind::Error, "REWIND_SALT must be set to hash webhook tokens"
      end

      OpenSSL::HMAC.hexdigest("SHA256", salt, plain.to_s)
    end

    def self.normalize_url(value)
      value.to_s.strip.sub(%r{/+\z}, "")
    end

    def validate
      super
      errors.add(:type, "must be jellyfin") unless TYPES.include?(type)
      errors.add(:url, "is required") if url.to_s.strip.empty?
      errors.add(:token, "is required") if token_digest.to_s.strip.empty?
      validates_unique(%i[type url], message: "is already allowlisted")
    end
  end
end
