# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:webhooks) do
      primary_key :id
      String :type, null: false
      String :url, null: false
      String :token_digest, null: false, unique: true
      TrueClass :enabled, null: false, default: true
      DateTime :last_event_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[type url], unique: true
    end

    create_table(:integrations) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      foreign_key :webhook_id, :webhooks, null: false, on_delete: :cascade
      String :external_user_id, null: false
      DateTime :last_event_at
      DateTime :disabled_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :user_id
      index %i[webhook_id external_user_id], unique: true
    end
  end
end
