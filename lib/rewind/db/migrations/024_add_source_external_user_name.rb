# frozen_string_literal: true

# The Jellyfin username a source signs in as, so Settings can show who each
# connection is (the user id alone is unreadable). Set when an account is
# linked and refreshed on every sync, so a rename shows up.
Sequel.migration do
  change do
    add_column :sources, :external_user_name, String
  end
end
