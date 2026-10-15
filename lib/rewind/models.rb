# frozen_string_literal: true

require "sequel"

Sequel::Model.db = Rewind.db
Sequel::Model.plugin :timestamps, update_on_create: true

require_relative "models/user"
require_relative "models/item"
require_relative "models/webhook"
require_relative "models/integration"
require_relative "models/play"
require_relative "models/user_item"
