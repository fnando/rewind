# frozen_string_literal: true

# A persistent, app-wide error log: an unhandled web exception or a sync
# failure is captured here with its full backtrace and the data that caused it
# (request/params/source context), so the admin error page can show everything
# about an error long after it happened.
#
# `admin` on users gates that page — the first account (lowest id) owns the
# instance, so it's made admin here; everyone else defaults to false.
Sequel.migration do
  up do
    create_table(:error_logs) do
      primary_key :id
      String :error_class, null: false
      String :message, text: true, null: false
      String :backtrace, text: true
      String :context_json, text: true
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :created_at
    end

    add_column :users, :admin, TrueClass, null: false, default: false
    first_id = from(:users).min(:id)
    from(:users).where(id: first_id).update(admin: true) if first_id
  end

  down do
    drop_column :users, :admin
    drop_table(:error_logs)
  end
end
