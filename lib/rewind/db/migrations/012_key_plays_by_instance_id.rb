# frozen_string_literal: true

# Dedupe synced plays by a stable instance id instead of the sources row's
# primary key. Deleting a source set every play's source_id to NULL
# (on_delete: :set_null); re-adding it got a new id, so the old
# (source_id, source_event_id) index couldn't tell a re-pulled play from the
# one already stored — and the full history doubled.
#
# instance_id is the provider's own identity (Jellyfin's ServerId). It lives as
# a plain string on `plays`, NOT a foreign key, so removing a source can never
# erase it. A re-added source for the same server computes the same instance_id,
# so its plays dedupe (and reconnect) again.
#
# Schema only: existing duplicate rows are deduped out of band (they carry a
# NULL instance_id, so this partial index doesn't enforce anything on them yet;
# the next sync backfills instance_id once the ServerId is known).
Sequel.migration do
  up do
    alter_table(:sources) { add_column :instance_id, String }
    alter_table(:plays) { add_column :instance_id, String }

    run "DROP INDEX IF EXISTS plays_source_event_uniq"
    run <<~SQL
      CREATE UNIQUE INDEX plays_user_instance_event_uniq
      ON plays (user_id, instance_id, source_event_id)
      WHERE instance_id IS NOT NULL AND source_event_id IS NOT NULL
    SQL
  end

  down do
    run "DROP INDEX IF EXISTS plays_user_instance_event_uniq"
    run <<~SQL
      CREATE UNIQUE INDEX plays_source_event_uniq
      ON plays (source_id, source_event_id)
      WHERE source_id IS NOT NULL AND source_event_id IS NOT NULL
    SQL
    alter_table(:plays) { drop_column :instance_id }
    alter_table(:sources) { drop_column :instance_id }
  end
end
