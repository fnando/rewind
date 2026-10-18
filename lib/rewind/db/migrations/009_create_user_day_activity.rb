# frozen_string_literal: true

# Derived table powering play streaks. One row per user, media group and local
# calendar day, counting the plays on it. It is fully rebuildable from `plays`
# (see Services::Streaks.rebuild_user) and kept in sync by Play's model hooks.
#
# `day` is the user's *local* day (SQLite has no named time zones, so the UTC ->
# local conversion happens in Ruby). `media_group` is the app display group
# (movie / series / music), not the raw items.media_type.
Sequel.migration do
  change do
    create_table(:user_day_activity) do
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :media_group, null: false
      String :day, null: false
      Integer :play_count, null: false

      primary_key %i[user_id media_group day]
      index %i[user_id day]
    end
  end
end
