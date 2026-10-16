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
- [Fixed] The webhook replay-dedup window compared a shadowed local variable
  instead of the `played_at` column, so it never actually scoped by time.
