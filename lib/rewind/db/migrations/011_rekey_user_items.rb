# frozen_string_literal: true

# Re-key ratings/reviews off a stable identity so they survive wiping and
# rebuilding `items` (whose local ids are regenerated on every rebuild).
#
# `user_items.item_key` is the Jellyfin item id when the item has one
# ("jellyfin:<id>") — stable across re-tagging/release swaps — otherwise
# "<media_type>:<external_id>" (stable TMDB/MBID for non-Jellyfin items). Items
# gain a nullable, non-unique `jellyfin_id` (a re-tag leaves two item rows
# sharing one). Data-destructive: existing ratings are dropped (start fresh).
Sequel.migration do
  up do
    alter_table(:items) do
      add_column :jellyfin_id, String
      add_index :jellyfin_id
    end

    drop_table(:user_items)
    create_table(:user_items) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :item_key, null: false
      Integer :rating
      String :review, text: true
      DateTime :review_created_at
      DateTime :review_updated_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      unique %i[user_id item_key]
    end
  end

  down do
    drop_table(:user_items)
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

    alter_table(:items) do
      drop_index :jellyfin_id
      drop_column :jellyfin_id
    end
  end
end
