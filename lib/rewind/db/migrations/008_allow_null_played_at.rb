# frozen_string_literal: true

# Some sources mark an item watched without recording *when* (e.g. Jellyfin
# items with Played=true but no LastPlayedDate). We keep those plays with a
# null played_at and show them as just "Watched".
Sequel.migration do
  up do
    alter_table(:plays) { set_column_allow_null :played_at }
  end

  down do
    alter_table(:plays) { set_column_not_null :played_at }
  end
end
