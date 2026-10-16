# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:items) do
      primary_key :id
      String :media_type, null: false
      String :external_id, null: false
      String :parent_external_id
      Integer :season_number
      Integer :episode_number
      String :title, null: false
      String :overview, text: true
      String :release_date
      String :poster_path
      Integer :runtime
      String :metadata_json, text: true
      DateTime :fetched_at, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      unique %i[media_type external_id]
      index :parent_external_id
    end
  end
end
