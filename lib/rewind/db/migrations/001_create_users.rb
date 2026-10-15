# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id
      String :username, null: false, unique: true
      String :name
      String :password_digest, null: false
      TrueClass :must_change_password, null: false, default: false
      String :rating_style, null: false, default: "stars"
      String :timezone, null: false, default: "UTC"
      DateTime :last_login_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
