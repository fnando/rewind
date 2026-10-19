# frozen_string_literal: true

# Admin-minted secrets for inbound webhooks (e.g. a Jellyfin instance posting to
# /webhooks/jellyfin/:secret). Only a salted SHA-256 of the secret is stored, so
# the raw value is shown once at creation and never recoverable. Secrets rotate
# in place; `enabled` lets one be revoked without deleting its row.
Sequel.migration do
  change do
    create_table(:webhooks) do
      primary_key :id
      String :name
      String :salt, null: false
      String :token_digest, null: false
      TrueClass :enabled, null: false, default: true
      DateTime :last_used_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :token_digest, unique: true
    end
  end
end
