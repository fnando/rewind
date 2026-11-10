-- Rewind schema, version 1. Instants are UTC text in a fixed format
-- (time::format), booleans are 0/1.

CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  name TEXT,
  password_digest TEXT NOT NULL,
  must_change_password INTEGER NOT NULL DEFAULT 0,
  rating_style TEXT NOT NULL DEFAULT 'stars',
  timezone TEXT NOT NULL DEFAULT 'UTC',
  admin INTEGER NOT NULL DEFAULT 0,
  last_login_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE sources (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  type TEXT NOT NULL,
  url TEXT NOT NULL,
  external_user_id TEXT NOT NULL,
  external_user_name TEXT,
  instance_id TEXT NOT NULL,
  credentials TEXT NOT NULL,
  cursor TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_synced_at TEXT,
  last_error_id INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX sources_user_id ON sources (user_id);
CREATE UNIQUE INDEX sources_account ON sources (user_id, type, instance_id, external_user_id);

CREATE TABLE source_errors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_id INTEGER NOT NULL REFERENCES sources ON DELETE CASCADE,
  message TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX source_errors_source_id ON source_errors (source_id);

CREATE TABLE items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  media_type TEXT NOT NULL,
  external_id TEXT NOT NULL,
  parent_external_id TEXT,
  season_number INTEGER,
  episode_number INTEGER,
  title TEXT NOT NULL,
  overview TEXT,
  release_date TEXT,
  poster_path TEXT,
  runtime INTEGER,
  metadata_json TEXT,
  jellyfin_id TEXT,
  source_etag TEXT,
  fetched_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (media_type, external_id)
);
CREATE INDEX items_parent_external_id ON items (parent_external_id);
CREATE INDEX items_jellyfin_id ON items (jellyfin_id);

-- One row per play. Jellyfin plays are keyed by the Rewind plugin's record id
-- (source_event_id = "rewind:<id>"). The local_* fields are where the play
-- happened on the user's clock, frozen at write.
CREATE TABLE plays (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  item_id INTEGER NOT NULL REFERENCES items ON DELETE CASCADE,
  source TEXT NOT NULL,
  source_id INTEGER REFERENCES sources ON DELETE SET NULL,
  instance_id TEXT,
  source_event_id TEXT,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  played_seconds INTEGER,
  progress REAL,
  local_date TEXT NOT NULL,
  local_time TEXT NOT NULL,
  local_hour INTEGER NOT NULL,
  local_weekday INTEGER NOT NULL,
  utc_offset_minutes INTEGER NOT NULL,
  timezone TEXT NOT NULL,
  client TEXT,
  device_name TEXT,
  play_method TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX plays_event ON plays (user_id, instance_id, source_event_id)
  WHERE instance_id IS NOT NULL AND source_event_id IS NOT NULL;
CREATE INDEX plays_user_item ON plays (user_id, item_id);
CREATE INDEX plays_user_started_at ON plays (user_id, started_at);
CREATE INDEX plays_user_local_date ON plays (user_id, local_date);
CREATE INDEX plays_user_local_hour ON plays (user_id, local_hour);
CREATE INDEX plays_user_local_weekday_hour ON plays (user_id, local_weekday, local_hour);

-- Ratings and reviews, keyed so they survive an item being rebuilt.
CREATE TABLE user_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  item_key TEXT NOT NULL,
  rating INTEGER,
  review TEXT,
  review_created_at TEXT,
  review_updated_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (user_id, item_key)
);

-- Every Jellyfin id we resolved, per server, for re-tag healing.
CREATE TABLE jellyfin_seen (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  instance_id TEXT NOT NULL,
  jellyfin_id TEXT NOT NULL,
  item_id INTEGER NOT NULL REFERENCES items ON DELETE CASCADE,
  media_type TEXT NOT NULL,
  recording_mbid TEXT,
  seen_at TEXT NOT NULL,
  UNIQUE (instance_id, jellyfin_id)
);
CREATE INDEX jellyfin_seen_recording_mbid ON jellyfin_seen (recording_mbid);
CREATE INDEX jellyfin_seen_item_id ON jellyfin_seen (item_id);

CREATE TABLE error_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  error_class TEXT NOT NULL,
  message TEXT NOT NULL,
  backtrace TEXT,
  context_json TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX error_logs_created_at ON error_logs (created_at);
