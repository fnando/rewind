# frozen_string_literal: true

# Give each source its own Jellyfin device id. We used to authenticate every
# connection with a hardcoded DeviceId="rewind"; Jellyfin binds a token to a
# device, so a second login on the same device id (another account, or the same
# account from dev vs prod against the same server) revoked the first's token —
# surfacing as "Jellyfin request unauthorized". A random, persisted device_id
# per source keeps their sessions independent.
#
# Nullable + no backfill: existing sources keep their "rewind"-bound token until
# they're reconnected (which mints a fresh one under a unique device_id).
Sequel.migration do
  change do
    alter_table(:sources) { add_column :device_id, String }
  end
end
