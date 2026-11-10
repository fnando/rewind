# rewind

[![CI](https://github.com/fnando/rewind/actions/workflows/ci.yml/badge.svg)](https://github.com/fnando/rewind/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/:License-MIT-blue.svg)](https://tldrlegal.com/license/mit-license)

A self-hosted media tracker — a lightweight alternative to Trakt / Letterboxd.
Log movies, TV episodes, and music manually, or connect your [Jellyfin] account
and Rewind syncs your play history automatically in the background. Movie and TV
metadata comes from [TMDB]; music is enriched via [MusicBrainz] (with cover art
from the [Cover Art Archive] and artist photos from [fanart.tv]). Everything is
stored in a single SQLite file, and Rewind ships as a single binary.

[Jellyfin]: https://jellyfin.org
[TMDB]: https://www.themoviedb.org
[MusicBrainz]: https://musicbrainz.org
[Cover Art Archive]: https://coverartarchive.org

Highlights:

- Multi-user, with per-user ratings, reviews, timezone and rating style (stars
  1–5 or thumbs).
- User management lives in the CLI — no self-serve registration. Privileged ops
  require shell access.
- Connect a Jellyfin account (username/password) and a background thread mirrors
  its play history from the [Rewind Jellyfin plugin][plugin]. Access tokens are
  stored encrypted at rest.
- Incremental, idempotent sync: each source tracks the plugin's change cursor,
  and every play is keyed on the plugin's own record id.
- Every play keeps when it happened, in UTC and in your local time as it was
  then, so changing your timezone never rewrites history.
- Time zone data updates itself daily, no restart needed.
- Dark/light theme follows the OS via `prefers-color-scheme`.

## Install

Download the archive for your platform from the
[latest release](https://github.com/fnando/rewind/releases/latest):

| Platform              | Archive                                    |
| --------------------- | ------------------------------------------ |
| macOS (Apple Silicon) | `rewind-aarch64-apple-darwin.tar.gz`       |
| Linux x86_64          | `rewind-x86_64-unknown-linux-gnu.tar.gz`   |
| Linux arm64           | `rewind-aarch64-unknown-linux-gnu.tar.gz`  |
| Linux x86_64 (static) | `rewind-x86_64-unknown-linux-musl.tar.gz`  |
| Linux arm64 (static)  | `rewind-aarch64-unknown-linux-musl.tar.gz` |

The static (musl) builds have no system dependencies, which makes them a good
fit for containers.

```bash
tar -xzf rewind-x86_64-unknown-linux-musl.tar.gz
sudo mv rewind /usr/local/bin/
```

### Verifying a download

Each release has a `SHA256SUMS` file, signed with the key in
[`rewind-signing-key.asc`](rewind-signing-key.asc) (fingerprint
`D366 096A 1522 F73D 01CA 1189 27DA F70E 8647 44F3`):

```bash
gpg --import rewind-signing-key.asc
gpg --verify SHA256SUMS.sig SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
```

### Requirements

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
rewind users new --username you

# 4. Start the server:
rewind run --port 55455
```

Open <http://localhost:55455>, sign in with the printed password, and change it
when prompted. The first user created is the admin.

## Configuration

Rewind reads its configuration from environment variables. You can keep them in
a `.env` file and pass `--env-file PATH` to any command.

| Variable                   | Default                   | Purpose                                                                                     |
| -------------------------- | ------------------------- | ------------------------------------------------------------------------------------------- |
| `REWIND_DATA_DIR`          | `./data`                  | Where the database, secrets, images, avatars and time zone data live.                       |
| `REWIND_HOST`              | `0.0.0.0`                 | Interface the server binds to.                                                              |
| `REWIND_PORT`              | `55455`                   | Port the server binds to.                                                                   |
| `REWIND_ALLOWED_HOSTS`     | _(empty)_                 | Comma-separated hostnames the server answers to. Empty allows any.                          |
| `REWIND_SECRET_KEY`        | auto-generated            | Base64 32-byte key that encrypts stored access tokens. Generated into `$REWIND_DATA_DIR/.secret_key`. |
| `REWIND_SESSION_SECRET`    | auto-generated            | Session cookie secret. Generated into `$REWIND_DATA_DIR/.session_secret`.                   |
| `REWIND_SYNC_INTERVAL`     | `60`                      | Seconds between background sync passes.                                                     |
| `REWIND_DB_BUSY_TIMEOUT`   | `15000`                   | Milliseconds to wait for a locked database.                                                 |
| `REWIND_IMAGE_STORAGE_DIR` | `$REWIND_DATA_DIR/images` | Where proxied cover images are cached.                                                      |
| `REWIND_AUTO_MIGRATE`      | _(unset)_                 | When `1`, pending migrations run on start.                                                  |
| `REWIND_LOG`               | _(unset)_                 | Log filter, e.g. `info` or `rewind=debug`.                                                  |
| `TMDB_API_KEY`             | _(required for metadata)_ | Your TMDB bearer token.                                                                     |
| `FANART_API_KEY`           | _(optional)_              | [fanart.tv] project key, used for artist photos. Without it, artists get a placeholder.     |

[fanart.tv]: https://fanart.tv/get-an-api-key/

Keep `REWIND_SECRET_KEY` (or the generated `.secret_key` file) stable: losing it
makes stored access tokens undecryptable, and users have to reconnect their
Jellyfin accounts. To set one yourself:

```bash
openssl rand -base64 32
```

Example `.env`:

```
REWIND_DATA_DIR=/var/lib/rewind
REWIND_ALLOWED_HOSTS=rewind.example.com,localhost
TMDB_API_KEY=eyJ…
```

```bash
rewind run --env-file .env
```

Behind a reverse proxy that terminates TLS, forward `X-Forwarded-Proto: https`
so the session cookie is marked secure.

## CLI reference

```bash
rewind run [--port N] [--host HOST] [--migrate]  # start the web server and background sync
rewind migrate                                   # run pending migrations
rewind config                                    # print resolved config (secrets redacted)
rewind version
```

User management:

```bash
rewind users new    --username USERNAME [--name NAME]
rewind users update --username USERNAME [--new-password] [--name NAME] \
                                        [--rating-style stars|thumbs] [--admin true|false]
rewind users delete --username USERNAME [--yes]
rewind users list
```

Connected sources (users connect them from Settings, so there's no `new`):

```bash
rewind sources list
rewind sources disable --id N
rewind sources enable  --id N
rewind sources delete  --id N [--yes]
```

Sync now, or re-import a source's plays from the plugin (deletes that source's
Jellyfin plays first; ratings, reviews and manual plays are kept):

```bash
rewind sync [--source N]
rewind sync --reset [--source N] [--yes]
```

The colon form also works (`rewind users:new`). Every command accepts
`--env-file PATH`, and `-v` / `--verbose-level LEVEL` for logging.

## Jellyfin integration

Plays come from the [Rewind Jellyfin plugin][plugin], which records every
playback session inside the server, from **any** client, and decides whether it
counts as a scrobble (music: half the track or 4 minutes; movies and episodes:
80% watched; "marked as played": always). Rewind reads the plugin's changes
feed and mirrors it: a scrobble becomes a play dated when playback started, and
a play the plugin deletes or stops counting (e.g. after its rules change) is
removed. Configure the thresholds in Jellyfin → Dashboard → Rewind.

1. Install the plugin on your Jellyfin server and restart Jellyfin.
2. Sign in → **Settings** → **Connect Jellyfin**.
3. Enter your **Jellyfin URL**, **username**, and **password**. Rewind checks
   that the server has the plugin, signs in once, and keeps the returned access
   token, encrypted. Your password is never stored. The token is scoped to your
   Jellyfin user, so Rewind only ever reads your own history.
4. Within one `REWIND_SYNC_INTERVAL` the background thread imports the plugin's
   history, then keeps it up to date. History and Stats fill in as items
   resolve via TMDB / MusicBrainz.

The plugin only knows plays from when it was installed. Pause or disconnect a
source any time from **Settings**.

### Troubleshooting

- **"Rewind plugin not installed"** on the source card: install the plugin on
  that server and restart Jellyfin.
- **Nothing syncs.** Confirm the source is enabled (`rewind sources list`). A
  revoked or expired token shows as a sync error — reconnect from Settings.
- **An item isn't recorded.** It couldn't be resolved: a movie/episode with
  neither a TMDB nor IMDB id, or an audio track with no title. It's listed on
  the errors page (**Settings** → errors); re-identify it in Jellyfin so it
  carries provider ids, then `rewind sync --reset --source N`.

[plugin]: https://github.com/fnando/jellyfin-rewind-plugin

## Database

A single SQLite file at `$REWIND_DATA_DIR/rewind.db`. Back it up by copying the
file while the server is stopped, or with SQLite's `.backup` command.

## Development

```bash
git clone https://github.com/fnando/rewind
cd rewind
make test     # run the tests
make check    # rustfmt + clippy (pedantic)
make fmt      # format the code
```

## Maintainer

- [Nando Vieira](https://github.com/fnando)

## Contributors

- https://github.com/fnando/rewind/contributors

## Contributing

For more details about how to contribute, please read
https://github.com/fnando/rewind/blob/main/CONTRIBUTING.md.

## License

Rewind is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT). A copy of the license can be
found at https://github.com/fnando/rewind/blob/main/LICENSE.md.

## Code of Conduct

Everyone interacting in the rewind project's codebases, issue trackers, chat
rooms and mailing lists is expected to follow the
[code of conduct](https://github.com/fnando/rewind/blob/main/CODE_OF_CONDUCT.md).
