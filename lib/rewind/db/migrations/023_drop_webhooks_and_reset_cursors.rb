# frozen_string_literal: true

# Plays now come from the Rewind Jellyfin plugin's changes feed. The webhook
# and the LastPlayedDate pull are gone: drop the webhook secrets, and clear the
# source cursors — they held LastPlayedDate strings, and the feed's cursor is a
# sequence number. Plays are left alone; `rewind sync --reset` replaces them.
Sequel.migration do
  up do
    drop_table?(:webhooks)
    from(:sources).update(cursor: nil)
  end

  down do
    create_table?(:webhooks) do
      primary_key :id
      String :name
      String :salt, null: false
      String :token_digest, null: false
      TrueClass :enabled, null: false, default: true
      DateTime :last_used_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :token_digest, unique: true
    end
  end
end
