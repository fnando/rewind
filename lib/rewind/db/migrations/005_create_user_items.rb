# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:user_items) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      foreign_key :item_id, :items, null: false, on_delete: :cascade
      Integer :rating
      String :review, text: true
      DateTime :review_created_at
      DateTime :review_updated_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      unique %i[user_id item_id]
    end
  end
end
