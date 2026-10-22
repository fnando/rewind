# frozen_string_literal: true

# Maps a synthetic music id onto its canonical MusicBrainz id. Written by
# `rewind artists:merge` when it collapses a duplicate (synthetic) artist onto
# its real mbid twin, and consulted at resolve-time (MusicBrainz#canonical) so a
# later untagged play that would re-mint the synthetic id routes to the mbid
# item instead of resurrecting the duplicate. from_external_id is unique — one
# canonical target per synthetic id.
Sequel.migration do
  change do
    create_table(:item_merges) do
      primary_key :id
      String :from_external_id, null: false
      String :to_external_id, null: false
      DateTime :created_at, null: false

      unique :from_external_id
      index :to_external_id
    end
  end
end
