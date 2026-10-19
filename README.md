# rewind-app

[![Tests](https://github.com/fnando/rewind/workflows/ruby-tests/badge.svg)](https://github.com/fnando/rewind)
[![Gem](https://img.shields.io/gem/v/rewind-app.svg)](https://rubygems.org/gems/rewind-app)
[![Gem](https://img.shields.io/gem/dt/rewind-app.svg)](https://rubygems.org/gems/rewind-app)
[![MIT License](https://img.shields.io/:License-MIT-blue.svg)](https://tldrlegal.com/license/mit-license)

A self-hosted media tracker — a lightweight alternative to Trakt / Letterboxd.
Log movies, TV episodes, and music manually, or connect your [Jellyfin] account
and Rewind syncs your play history automatically in the background. Movie and TV
metadata comes from [TMDB]; music is enriched via [MusicBrainz] (with cover art
from the [Cover Art Archive] and artist photos from [fanart.tv]). Stores
everything in a single SQLite file.

[Jellyfin]: https://jellyfin.org
[TMDB]: https://www.themoviedb.org
[MusicBrainz]: https://musicbrainz.org
[Cover Art Archive]: https://coverartarchive.org

Highlights:

- Multi-user, with per-user ratings, reviews, timezone and rating style (stars
  1–5 or thumbs).
- All user management lives in the CLI — no self-serve registration, no admin
  UI, no in-app admin role. Privileged ops require shell access.
- Connect a Jellyfin account (username/password) and a background thread polls
  its play history. An optional Jellyfin webhook adds a real-time push path, so
  a play missed by one is usually caught by the other. Access tokens are stored
  encrypted at rest.
- Incremental, idempotent sync: each source tracks a cursor and dedupes plays.
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
| `REWIND_KEYRING`        | _(required for sources)_  | JSON keyring used to encrypt connected sources' access tokens, e.g. `{"1":"<base64 32-byte key>"}`.    |
| `REWIND_SYNC_INTERVAL`  | `60`                      | Seconds between background sync passes.                                                                |
| `REWIND_AUTO_MIGRATE`   | _(unset)_                 | When `1`, boot runs pending migrations automatically.                                                 |
| `REWIND_PUMA_PLUGINS`   | _(empty)_                 | Comma-separated extra Puma plugins to load on top of the built-in `tmp_restart`.                      |
| `TMDB_API_KEY`          | _(required for metadata)_ | Your TMDB bearer token.                                                                               |
| `FANART_API_KEY`        | _(optional)_              | [fanart.tv] project key, used for artist photos. Without it, artists fall back to a placeholder.      |

[fanart.tv]: https://fanart.tv/get-an-api-key/

`REWIND_KEYRING` is required before anyone connects a source — it encrypts the
Jellyfin access tokens Rewind stores. Generate a key and wrap it in a keyring:

```bash
echo "{\"1\":\"$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | openssl base64 -A)\"}"
```

Keep the key stable (losing it makes existing tokens undecryptable — users just
reconnect). To rotate, add a new id (`"2": …`) and keep the old key around so
existing rows can be re-encrypted on save.

Example `.env`:

```
REWIND_DATA_DIR=/var/lib/rewind
REWIND_ALLOWED_HOSTS=rewind.example.com,localhost
REWIND_KEYRING={"1":"<base64 key>"}
TMDB_API_KEY=eyJ…
```

```bash
rewind run --env .env
```

## CLI reference

```bash
rewind migrate                                 # run all pending migrations
rewind run [--port N] [--host HOST] [--workers N] [--threads N] [-e ENV] [-v]  # start the web server (puma)
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

Any CLI command accepts `--env-file PATH` to load a dotenv file first, and
`--environment NAME` / `-e` to set the run environment (defaults to
`production`, falling back to `APP_ENV`/`RACK_ENV`).

Operators can inspect/cleanup connected sources (users connect them from
Settings, so there's no `new`):

```bash
rewind sources:list
rewind sources:disable --id N
rewind sources:enable  --id N
rewind sources:delete  --id N [--yes]
```

Webhook secrets (for the Jellyfin webhook fallback below) are admin-minted and
stored only as a salted hash:

```bash
rewind webhooks:new [--name LABEL]   # mint a secret (shown once) + its URL path
rewind webhooks:list
rewind webhooks:rotate --id N        # replace the secret
rewind webhooks:revoke --id N        # disable without deleting
```

## Jellyfin integration

Rewind polls the Jellyfin API on a schedule and records every play newer than
the last sync — so plays from **any** client are captured, including apps that
never fire webhooks. (`REWIND_KEYRING` must be set so the access token can be
stored encrypted.)

1. Sign in → **Settings** → **Connect Jellyfin**.
2. Enter your **Jellyfin URL**, **username**, and **password**. Rewind signs in
   once via Jellyfin's `AuthenticateByName`, keeps the returned access token
   (encrypted — your password is never stored), and records your Jellyfin user
   id so it only ever reads your own history.
3. Within one `REWIND_SYNC_INTERVAL` the background thread backfills your whole
   played history, then keeps it up to date. History and Stats fill in as items
   resolve via TMDB / MusicBrainz.

Pause or disconnect a source any time from **Settings**. The access token is
scoped to your Jellyfin user, so Rewind can only read your own plays.

### Webhook fallback (optional)

Polling is best-effort: some clients don't reliably settle a track's played
state, so the odd listen is missed. Jellyfin's **Webhook** plugin can push a
notification the moment a track finishes, as a second, redundant source — a play
seen by either path is recorded, and de-duplicated when both see it. Today only
music (audio) is recorded via the webhook; movies and episodes still come from
polling.

1. Mint a secret and note its URL path (shown once):

   ```bash
   rewind webhooks:new --name mediabox
   #   path:  /webhooks/jellyfin/<secret>
   ```

2. In Jellyfin, install the **Webhook** plugin → **Add Generic Destination**:
   - **Webhook URL:** `https://your-rewind-host/webhooks/jellyfin/<secret>`
   - **Notification Type:** _Playback Stop_
   - Leave the default JSON template — Rewind reads the track's MusicBrainz ids,
     your user id, and `PlayedToCompletion` from the standard payload.

3. Save. Finished music plays now arrive in real time; whatever the webhook
   misses is still caught by the next poll, and vice versa.

The secret is the only auth, so treat the URL like a password; rotate or revoke
it with `rewind webhooks:rotate`/`webhooks:revoke`.

> **Note:** both paths are best-effort — Jellyfin (and some clients) can fail to
> report a play to either one. Running pull and push together makes a missed
> track far less likely, but not impossible; the occasional listen may still
> never be recorded.

### Troubleshooting

- **Nothing syncs.** Confirm `REWIND_KEYRING` is set and the source is enabled
  (`rewind sources:list`). A revoked/expired token auto-disables the source —
  reconnect from Settings.
- **An item isn't recorded.** It couldn't be resolved: a movie/episode with
  neither a TMDB nor IMDB id, or an audio track with no title. Re-identify it in
  Jellyfin so it carries provider ids.
- **A music play is missing.** Polling relies on the client settling the track's
  played state, which some 3rd-party clients do unreliably. Enable the webhook
  fallback (above) so finished tracks are pushed in real time too. (A client
  that plays fully offline and never tells the server still can't be seen.)

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
