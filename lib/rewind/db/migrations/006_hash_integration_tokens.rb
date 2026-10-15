# frozen_string_literal: true

require "openssl"

Sequel.migration do
  up do
    alter_table(:integrations) do
      add_column :token_digest, String
    end

    salt = ENV["REWIND_SALT"].to_s
    rows = from(:integrations).select(:id, :token).all
    if rows.any? && salt.empty?
      raise "REWIND_SALT must be set to migrate existing integration tokens"
    end

    rows.each do |row|
      digest = OpenSSL::HMAC.hexdigest("SHA256", salt, row[:token].to_s)
      from(:integrations).where(id: row[:id]).update(token_digest: digest)
    end

    alter_table(:integrations) { drop_column :token }
    alter_table(:integrations) { add_index :token_digest, unique: true }
  end

  down do
    alter_table(:integrations) do
      add_column :token, String
      drop_column :token_digest
    end
  end
end
