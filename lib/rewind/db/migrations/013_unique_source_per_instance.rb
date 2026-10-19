# frozen_string_literal: true

# Identify a source by the server it connects to, not its URL. A Jellyfin
# ServerId is stable for a given database; the URL is not (reverse proxy,
# internal vs public host), so keying uniqueness on the URL let the same
# account on the same server be connected twice — which doubled the history.
#
# Swap `url` for `instance_id` in the key. The rest stays: scoped per rewind
# user (credentials are per user) and per Jellyfin account (external_user_id),
# so one user can still connect the same server as two different accounts.
#
# NB: a unique index needs the data to already satisfy it — there must be no
# existing (user_id, type, instance_id, external_user_id) duplicates. Sources
# hold credentials, so we never delete them here; consolidate out of band first.
Sequel.migration do
  up do
    run "DROP INDEX IF EXISTS sources_user_id_type_url_external_user_id_index"
    run <<~SQL
      CREATE UNIQUE INDEX sources_user_type_instance_account_uniq
      ON sources (user_id, type, instance_id, external_user_id)
    SQL
  end

  down do
    run "DROP INDEX IF EXISTS sources_user_type_instance_account_uniq"
    run <<~SQL
      CREATE UNIQUE INDEX sources_user_id_type_url_external_user_id_index
      ON sources (user_id, type, url, external_user_id)
    SQL
  end
end
