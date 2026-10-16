# frozen_string_literal: true

# Replace the push-webhook model (webhooks + integrations) with per-user,
# per-provider sync `sources` holding an encrypted access token. up-only: the
# old push data is disposable and we never roll this back.
Sequel.migration do
  up do
    create_table(:sources) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :type, null: false
      String :url
      String :external_user_id
      String :encrypted_credentials, text: true
      Integer :keyring_id
      String :cursor
      TrueClass :enabled, null: false, default: true
      DateTime :last_synced_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :user_id
      index %i[user_id type url external_user_id], unique: true
    end

    run "DROP INDEX IF EXISTS plays_integration_event_uniq"

    alter_table(:plays) do
      add_foreign_key :source_id, :sources, on_delete: :set_null
      drop_column :integration_id
    end

    run <<~SQL
      CREATE UNIQUE INDEX plays_source_event_uniq
      ON plays (source_id, source_event_id)
      WHERE source_id IS NOT NULL AND source_event_id IS NOT NULL
    SQL

    drop_table :integrations
    drop_table :webhooks
  end
end
