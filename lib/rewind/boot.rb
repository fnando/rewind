# frozen_string_literal: true

# Central load point for Rewind's domain code — models and services. Required by
# Rewind.boot! once the database is configured (models bind to Rewind.db at load
# time), so every entry point — the CLI commands and the web app alike — goes
# through the same place and nothing has to require services ad-hoc.
#
# The web layer (lib/rewind/application.rb) builds on top of this with Sinatra,
# the view helpers and the routes.

require_relative "models"

require_relative "services/password_generator"
require_relative "services/fanart"
require_relative "services/tmdb"
require_relative "services/musicbrainz"
require_relative "services/music_video"
require_relative "services/jellyfin"
require_relative "services/sources/jellyfin"
require_relative "services/sync"
require_relative "services/play_dedup"
require_relative "services/music_merge"
require_relative "services/music_rekey"
require_relative "services/jellyfin_archive"
require_relative "services/stats"
require_relative "services/streaks"
require_relative "services/avatar"
require_relative "services/image_cache"
require_relative "services/timezone_data"
require_relative "services/webhooks/jellyfin"
require_relative "services/importers/trakt"
