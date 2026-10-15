# frozen_string_literal: true

require "sequel"

module Rewind
  module Migrator
    extend self

    def migrate!
      Sequel.extension :migration
      Sequel::Migrator.run(Rewind.db, Rewind.config.migrations_dir)
    end

    def pending?
      Sequel.extension :migration
      !Sequel::Migrator.is_current?(Rewind.db, Rewind.config.migrations_dir)
    end
  end
end
