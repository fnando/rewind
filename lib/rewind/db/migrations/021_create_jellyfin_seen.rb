# frozen_string_literal: true

# A ledger of every Jellyfin item id we've ever resolved, so a file that's
# re-tagged into a new id can be tied back to the row we already keep. Jellyfin
# mints an item id from the file path, so re-tagging (which renames/moves the
# file) gives the same audio a brand-new id and would otherwise strand its
# play. We record the id -> item mapping plus, for tracks, the MusicBrainz
# recording — the one id that survives a re-tag (Picard preserves it, and
# MusicBrainz keeps one recording across releases). When a new id's recording
# matches a prior played row whose own file is gone, the play is moved onto the
# correctly-tagged row (Services::JellyfinArchive).
#
# A Jellyfin id is only unique within its server, so the natural key is
# (instance_id, jellyfin_id). recording_mbid is set on tracks only and indexed
# for the reverse lookup that drives the re-tag healing.
Sequel.migration do
  change do
    create_table(:jellyfin_seen) do
      primary_key :id
      String :jellyfin_id, null: false
      foreign_key :item_id, :items, null: false, on_delete: :cascade
      String :media_type, null: false
      String :recording_mbid
      String :instance_id
      DateTime :seen_at, null: false

      unique %i[instance_id jellyfin_id]
      index :recording_mbid
      index :item_id
    end
  end
end
