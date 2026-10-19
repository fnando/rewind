# frozen_string_literal: true

# Keep a log of sync errors per source so a resolved error is still viewable
# ("See previous error") instead of vanishing the moment the next sync succeeds.
# The source points at its current (unresolved) error via last_error_id, which
# is nulled on a successful sync — the source_errors rows themselves are kept.
#
# last_error_id is a plain integer (model-level association, no DB foreign key)
# on purpose: adding an FK column forces SQLite to rebuild the table, dropping
# the unique indexes from migrations 012/013. Plain add_column does not rebuild.
Sequel.migration do
  change do
    create_table(:source_errors) do
      primary_key :id
      foreign_key :source_id, :sources, null: false, on_delete: :cascade
      String :message, text: true, null: false
      DateTime :created_at, null: false
      index :source_id
    end

    alter_table(:sources) { add_column :last_error_id, Integer }
  end
end
