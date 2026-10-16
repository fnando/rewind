# Changelog

<!--
Prefix your message with one of the following:

- [Added] for new features.
- [Changed] for changes in existing functionality.
- [Deprecated] for soon-to-be removed features.
- [Removed] for now removed features.
- [Fixed] for any bug fixes.
- [Security] in case of vulnerabilities.
-->

## Unreleased

- Initial release.
- [Added] Music tracking: artist/album/track items enriched via MusicBrainz,
  with cover art from the Cover Art Archive and artist photos from fanart.tv.
  Music plays arrive through the existing Jellyfin webhook (`Audio` events) and
  surface on the stats page (top artists/albums/tracks).
- [Changed] Items are now identified by a prefixed `external_id` (`tmdb:…`,
  `mbid:…`) instead of a TMDB-specific `tmdb_id` column.
- [Changed] Jellyfin ingestion moved from push webhooks to a background sync
  thread that polls the Jellyfin API per user — capturing plays from every
  client, not just ones that fire webhooks. Users connect their account with
  their Jellyfin username/password (Settings → Connect Jellyfin); the resulting
  access token is stored encrypted via `attr_keyring` (`REWIND_KEYRING`).
- [Removed] The push-webhook endpoint, token model, and `webhooks:*` CLI, plus
  the now-unused `REWIND_SALT`. Server connections are modeled as per-user
  `sources` behind pluggable provider adapters (Jellyfin today; Plex/Spotify/
  Apple Music later). Managed with `rewind sources:*`.
