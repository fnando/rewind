# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:integrations) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :kind, null: false
      String :label, null: false
      String :instance_url
      String :token, null: false, unique: true
      String :external_user_id
      String :settings_json, text: true
      DateTime :last_event_at
      DateTime :disabled_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[user_id kind]
    end
  end
end
