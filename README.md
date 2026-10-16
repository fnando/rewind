# rewind-app

[![Tests](https://github.com/fnando/rewind/workflows/ruby-tests/badge.svg)](https://github.com/fnando/rewind)
[![Gem](https://img.shields.io/gem/v/rewind-app.svg)](https://rubygems.org/gems/rewind-app)
[![Gem](https://img.shields.io/gem/dt/rewind-app.svg)](https://rubygems.org/gems/rewind-app)
[![MIT License](https://img.shields.io/:License-MIT-blue.svg)](https://tldrlegal.com/license/mit-license)

A self-hosted media watching tracker — a lightweight alternative to Trakt /
Letterboxd. Log movies and TV episodes manually, or let [Jellyfin] push playback
events to it via webhook. All metadata comes from [TMDB]. Stores everything in a
single SQLite file.

[Jellyfin]: https://jellyfin.org
[TMDB]: https://www.themoviedb.org

Highlights:

- Multi-user, with per-user ratings, reviews, timezone and rating style (stars
  1–5 or thumbs).
- All user management lives in the CLI — no self-serve registration, no admin
  UI, no in-app admin role. Privileged ops require shell access.
- Pluggable integrations: each user can register many Jellyfin instances with
  their own webhook URL.
- Watch is logged automatically once a playback crosses 85%, or on completion.
- Session-aware deduplication so one playback never records multiple plays.
- Dark/light theme follows the OS via `prefers-color-scheme`.

## Install

```bash
gem install rewind-app
```

This installs the `rewind` executable.

### Requirements

- Ruby 4.0 or newer.
- A [TMDB API key][tmdb-api] (free, personal use).

[tmdb-api]: https://www.themoviedb.org/settings/api

## Quick start

```bash
# 1. Pick a data directory and a TMDB key:
export REWIND_DATA_DIR=~/.local/share/rewind
export TMDB_API_KEY=…your-tmdb-key…

# 2. Create the database:
rewind migrate

# 3. Create your first user (prints a one-time password):
rewind users:new --username you

# 4. Start the server:
rewind run --port 55455
```

Open <http://localhost:55455>, sign in with the printed password, and change it
when prompted.

## Configuration

Rewind reads its configuration from environment variables. You can keep them in
a `.env` file and pass `--env PATH` to any CLI command.

| Variable                | Default                   | Purpose                                                                                               |
| ----------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------- |
| `REWIND_DATA_DIR`       | `./data`                  | Where the SQLite file and session secret live.                                                        |
| `REWIND_HOST`           | `0.0.0.0`                 | Interface the server binds to.                                                                        |
| `REWIND_PORT`           | `55455`                   | Port the server binds to.                                                                             |
| `REWIND_ALLOWED_HOSTS`  | _(empty)_                 | Comma-separated hostnames allowed by Sinatra's host authorization.                                    |
| `REWIND_SESSION_SECRET` | auto-generated            | Rack session cookie secret. Generated into `$REWIND_DATA_DIR/.session_secret` on first run.           |
| `REWIND_SALT`           | _(required)_              | Secret used to hash integration webhook tokens. Must stay stable, or existing webhooks stop matching. |
| `REWIND_AUTO_MIGRATE`   | _(unset)_                 | When `1`, boot runs pending migrations automatically.                                                 |
| `REWIND_PUMA_PLUGINS`   | _(empty)_                 | Comma-separated extra Puma plugins to load on top of the built-in `tmp_restart`.                      |
| `TMDB_API_KEY`          | _(required for metadata)_ | Your TMDB bearer token.                                                                               |

`REWIND_SALT` is required. Generate one with:

```bash
dd if=/dev/urandom bs=32 count=1 2>/dev/null | openssl base64 -A
```

Set it once and keep it stable — webhook tokens are stored only as HMAC-SHA256
digests of this salt, so changing it invalidates every existing webhook URL.

Example `.env`:

```
REWIND_DATA_DIR=/var/lib/rewind
REWIND_ALLOWED_HOSTS=rewind.example.com,localhost
REWIND_SALT=<salt here>
TMDB_API_KEY=eyJ…
```

```bash
rewind run --env .env
```

## CLI reference

```bash
rewind migrate                                 # run all pending migrations
rewind run [--port N] [--host HOST] [--verbose]  # start the web server (puma)
rewind restart                                 # restart a running server (touches tmp/restart.txt)
rewind console                                 # IRB with models loaded
rewind config                                  # print resolved config (secrets redacted)
rewind version
```

User management (CLI-only — there is no in-app admin):

```bash
rewind users:new    --username USERNAME [--name NAME]
rewind users:update --username USERNAME [--new-password] [--name NAME] \
                                        [--rating-style stars|thumbs]
rewind users:delete --username USERNAME [--yes]
rewind users:list
```

Any CLI command accepts `--env PATH` to load a dotenv file first.

## Jellyfin integration

Rewind receives playback events from Jellyfin's official
[Webhook plugin](https://github.com/jellyfin/jellyfin-plugin-webhook). Each
rewind user can register many Jellyfin instances; each gets its own webhook URL
that can be revoked at any time.

### 1. In Rewind

- Sign in → **Settings** → **Integrations** → _Add integration_.
- Fill in:
  - **Label**: friendly name (e.g. _Living room_).
  - **Instance URL**: your Jellyfin URL (used for display).
  - **Jellyfin user ID**: optional. If your Jellyfin has multiple users, paste
    yours so events from other users are ignored. Find it under Jellyfin →
    Dashboard → Users → your user → URL contains `userId=…`.
- Copy the generated webhook URL.

### 2. In Jellyfin

- Install the Webhook plugin:
  1. Dashboard → Plugins → **Manage Repositories**. If the official repository
     isn't listed, add `https://repo.jellyfin.org/files/plugin/manifest.json`.
  2. Restart Jellyfin.
  3. Dashboard → Plugins → find **Webhook** in the list and enable it.
- Dashboard → Plugins → **Webhook** → **Add Generic Destination**.
- Fields:
  - **Webhook URL**: paste the one from Rewind.
  - **Notification Type**: tick **all of these**:
    - **Playback Start**
    - **Playback Progress** (so a watch is recorded at ≥85% even if the user
      doesn't finish).
    - **Playback Stop** (so natural completion is recorded; combined with
      Progress, Rewind collapses them into a single play per session).
  - **Item Types**: enable **Movies** and **Episodes**.
  - **User filter**: pick your user (recommended even if you set the user id in
    Rewind — belt and suspenders).
  - **Template**: paste the one shown on Rewind's Settings page. It includes the
    TMDB/IMDB provider ids, play session id, and position/runtime so Rewind can:
    - Record a watch when position reaches ≥85% of runtime.
    - Collapse all the progress + stop events of a single viewing into one play.
    - Fall back to TMDB's `/find?external_source=imdb_id` when the item only has
      an IMDB id in Jellyfin.
- Save.

Trigger a playback past 85% and refresh History — the play should appear.

### Troubleshooting

- **Server receives events but nothing is recorded.** Check the server log for
  lines like `[webhook/jellyfin] skipped: ignored_event payload=…`. Common
  reasons:
  - `user_mismatch` — the integration's "Jellyfin user ID" doesn't match the one
    in the payload.
  - `no_tmdb_id` — the item has neither TMDB nor IMDB ids in Jellyfin.
    Re-identify the show/movie in Jellyfin.
- **Host rejected.** Add the hostname Jellyfin uses to reach Rewind to
  `REWIND_ALLOWED_HOSTS`.
- **Multiple instances.** Add one integration per Jellyfin install; each gets
  its own webhook URL and its own idempotency scope, so two instances with
  colliding internal item ids won't fight.

## Importing from Trakt

Migrating from [Trakt]? Request a data export (trakt.tv → _Settings_ → _Data_)
and you'll get a `.zip` of JSON files. Import your history into an existing
Rewind user with:

```bash
rewind import:trakt --archive trakt-export.zip --username you
```

This imports:

- **Watchings** from `watched-history.json` (movies and episodes), each as a
  play attributed to the user.
- **Ratings** from `ratings-{movies,shows,episodes}.json`. Trakt's 1–10 scale is
  mapped to Rewind's 1–5.
- **Reviews** from `comments-{movies,shows,episodes}.json`.

Items are resolved through TMDB using the tmdb ids in the export, so
`TMDB_API_KEY` must be set (see [Configuration](#configuration)). Season-level
ratings/comments, lists, and private notes are not imported. The import is safe
to re-run: watchings are de-duplicated by their Trakt history id, so you can
re-import an updated export without creating duplicate plays.

## Running under your own stack

For Docker, systemd, or a custom Rack app, write a `config.ru`:

```ruby
require "rewind"

Rewind.boot!   # loads config from ENV, connects the DB, loads models

run Rewind.application
```

```bash
puma -p 55455 config.ru
```

Set `REWIND_AUTO_MIGRATE=1` to run migrations on boot, or run `rewind migrate`
as a release step.

`rewind run` launches Puma with the built-in `tmp_restart` plugin enabled, so a
running server can be restarted by touching `tmp/restart.txt` in its working
directory. Load additional Puma plugins with `REWIND_PUMA_PLUGINS`.

## Database

A single SQLite file at `$REWIND_DATA_DIR/rewind.sqlite3`. Back it up by copying
the file (while the server is idle or after a `.backup` SQLite command). No
external services required.

## Development

```bash
git clone https://github.com/fnando/rewind
cd rewind
bundle install
bundle exec rake test       # minitest + rack-test + webmock
bundle exec rubocop         # lint (rubocop-fnando)
```

## Maintainer

- [Nando Vieira](https://github.com/fnando)

## Contributors

- https://github.com/fnando/rewind/contributors

## Contributing

For more details about how to contribute, please read
https://github.com/fnando/rewind/blob/main/CONTRIBUTING.md.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT). A copy of the license can be
found at https://github.com/fnando/rewind/blob/main/LICENSE.md.

## Code of Conduct

Everyone interacting in the rewind-app project's codebases, issue trackers, chat
rooms and mailing lists is expected to follow the
[code of conduct](https://github.com/fnando/rewind/blob/main/CODE_OF_CONDUCT.md).
