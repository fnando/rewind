# frozen_string_literal: true

# Jellyfin returns an Etag per item that changes whenever the item's metadata
# changes. Storing it lets the sync skip re-resolving (and re-backfilling) an
# item whose Etag is unchanged — turning a re-scan into a cheap lookup — while
# still refreshing anything that actually changed. Nullable: existing rows
# resolve once more to populate it, then stay put.
Sequel.migration do
  change do
    alter_table(:items) do
      add_column :source_etag, String
    end
  end
end
