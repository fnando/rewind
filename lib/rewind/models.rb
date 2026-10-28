# frozen_string_literal: true

require "sequel"

Sequel::Model.db = Rewind.db
Sequel::Model.plugin :timestamps, update_on_create: true

require_relative "models/user"
require_relative "models/item"
require_relative "models/source"
require_relative "models/source_error"
require_relative "models/user_timezone_entry"
require_relative "models/play"
require_relative "models/user_item"
require_relative "models/webhook"
require_relative "models/error_log"
