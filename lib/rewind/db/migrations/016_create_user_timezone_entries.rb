# frozen_string_literal: true

# Freeze the timezone context each play happened in, so history can be grouped
# by local day entirely in SQL (SQLite has no named time zones) and so changing
# a user's timezone never rewrites the past.
#
# A play points at the `(name, offset)` the user was in at that instant — PST
# and PDT are distinct entries, resolved via TZInfo at write time. `local_date`
# is the frozen local calendar day derived from `played_at` + that offset; it is
# the indexed column the history pagination reads. Both are immutable: a later
# timezone change only affects future plays.
#
# NB: `add_column` is native on SQLite (no table rebuild), so the partial unique
# index on `plays` survives — unlike FK/column-nullability changes (see
# migration 010). The FK to user_timezone_entries is enforced at the model
# layer to keep it that way.
Sequel.migration do
  up do
    create_table(:user_timezone_entries) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :name, null: false
      Integer :offset, null: false # UTC offset in seconds at the play's instant
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[user_id name offset], unique: true
    end

    alter_table(:plays) do
      add_column :user_timezone_entry_id, Integer
      add_column :local_date, String # 'YYYY-MM-DD' in the user's local zone
      add_index %i[user_id local_date]
    end

    # Backfill existing plays. We never captured historical zones, so each play
    # is resolved under its user's *current* timezone — matching how the app
    # grouped history before this change. Raw datasets, so no play hooks fire.
    require "tzinfo"
    zones = self[:users].select_hash(:id, :timezone)
    entry_ids = {} # [user_id, name, offset] => user_timezone_entries.id
    now = Time.now

    self[:plays].exclude(played_at: nil)
                .select(:id, :user_id, :played_at).all.each do |play|
      name = zones[play[:user_id]] || "UTC"
      tz =
        begin
          TZInfo::Timezone.get(name)
        rescue TZInfo::InvalidTimezoneIdentifier
          name = "UTC"
          TZInfo::Timezone.get("UTC")
        end

      utc = play[:played_at].to_time.utc
      offset = tz.period_for(utc).observed_utc_offset
      local_date = (utc + offset).to_date.iso8601

      entries = self[:user_timezone_entries]
      entry_id = entry_ids[[play[:user_id], name, offset]] ||=
        entries.where(user_id: play[:user_id], name:, offset:).get(:id) ||
        entries.insert(
          user_id: play[:user_id], name:, offset:,
          created_at: now, updated_at: now
        )

      self[:plays].where(id: play[:id])
                  .update(user_timezone_entry_id: entry_id, local_date:)
    end
  end

  down do
    alter_table(:plays) do
      drop_index %i[user_id local_date]
      drop_column :local_date
      drop_column :user_timezone_entry_id
    end

    # Dropping columns rebuilds the `plays` table on SQLite, which silently
    # drops this partial index (see migration 010); re-create it afterwards.
    run <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS plays_user_instance_event_uniq
      ON plays (user_id, instance_id, source_event_id)
      WHERE instance_id IS NOT NULL AND source_event_id IS NOT NULL
    SQL

    drop_table(:user_timezone_entries)
  end
end
