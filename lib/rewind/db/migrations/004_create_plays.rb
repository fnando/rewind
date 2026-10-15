# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:plays) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      foreign_key :item_id, :items, null: false, on_delete: :cascade
      foreign_key :integration_id, :integrations, on_delete: :set_null
      DateTime :played_at, null: false
      String :source, null: false
      String :source_event_id
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[user_id played_at]
      index %i[user_id item_id]
    end

    run <<~SQL
      CREATE UNIQUE INDEX plays_integration_event_uniq
      ON plays (integration_id, source_event_id)
      WHERE integration_id IS NOT NULL AND source_event_id IS NOT NULL
    SQL
  end
end
