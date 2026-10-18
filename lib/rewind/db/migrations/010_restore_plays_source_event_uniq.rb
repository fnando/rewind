# frozen_string_literal: true

# Restore the unique index that dedupes synced plays by (source_id,
# source_event_id). It was created in migration 006 with a raw CREATE UNIQUE
# INDEX, but migration 008 (set_column_allow_null :played_at) made SQLite
# rebuild the `plays` table, and Sequel's emulated rebuild silently dropped this
# partial index. Without it, re-imports could insert duplicate plays.
#
# NB: if a future migration alters the `plays` table again, re-add this index
# afterwards for the same reason — Sequel's SQLite table rebuild does not
# preserve partial indexes.
Sequel.migration do
  up do
    # Drop existing duplicates first (keeping the earliest row), so the unique
    # index can be created. Only rows that carry both a source_id and a
    # source_event_id are deduped; manual plays (both null) are left untouched.
    run <<~SQL
      DELETE FROM plays
      WHERE source_id IS NOT NULL
        AND source_event_id IS NOT NULL
        AND id NOT IN (
          SELECT min(id) FROM plays
          WHERE source_id IS NOT NULL AND source_event_id IS NOT NULL
          GROUP BY source_id, source_event_id
        )
    SQL

    run <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS plays_source_event_uniq
      ON plays (source_id, source_event_id)
      WHERE source_id IS NOT NULL AND source_event_id IS NOT NULL
    SQL
  end

  down do
    run "DROP INDEX IF EXISTS plays_source_event_uniq"
  end
end
