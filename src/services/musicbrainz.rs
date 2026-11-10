//! Builds the artist → album → track chain of items for a played song.
//!
//! Identity comes straight from the file tags: MusicBrainz ids when the
//! library is tagged, otherwise deterministic synthetic keys derived from the
//! text. The MusicBrainz API is never called — a lookup that intermittently
//! hits or misses would split one song into two items. Identity is
//! release-scoped: an album is its release, a track its release-track; never
//! the release group (too coarse) or the recording (shared across editions).
//!
//! Every resolve upserts the rows from the data in hand, so fields stay
//! current. The one remote piece is the artist photo (fanart.tv), reused once
//! stored.

use anyhow::Result;
use rusqlite::Connection;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::fanart::Fanart;
use crate::config::Config;
use crate::models::item::{Attrs, Item};

#[must_use]
pub fn track_external_id(release_track_mbid: Option<&str>) -> Option<String> {
    presence(release_track_mbid).map(|m| format!("mbid:rt:{m}"))
}

#[must_use]
pub fn album_external_id(release_mbid: Option<&str>) -> Option<String> {
    presence(release_mbid).map(|m| format!("mbid:release:{m}"))
}

#[must_use]
pub fn artist_external_id(artist_mbid: &str) -> String {
    format!("mbid:artist:{artist_mbid}")
}

fn presence(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|v| !v.is_empty())
}

fn synthetic_id(kind: &str, text: &str) -> String {
    let digest = Sha256::digest(text.to_lowercase().as_bytes());
    format!("mbid:synthetic:{kind}:{}", hex::encode(digest))
}

/// Everything known about a played track.
#[derive(Debug, Clone, Default)]
pub struct TrackInput<'a> {
    pub title: &'a str,
    pub artist: Option<&'a str>,
    pub album: Option<&'a str>,
    pub release_track_mbid: Option<&'a str>,
    pub release_mbid: Option<&'a str>,
    pub artist_mbid: Option<&'a str>,
    pub length_ms: Option<i64>,
    pub track_number: Option<i64>,
    pub disc_number: Option<i64>,
    pub release_date: Option<&'a str>,
    pub genres: Vec<String>,
    pub jellyfin_id: Option<&'a str>,
    pub album_jellyfin_id: Option<&'a str>,
}

/// Everything known about an album, without a track.
#[derive(Debug, Clone, Default)]
pub struct AlbumInput<'a> {
    pub title: &'a str,
    pub artist: Option<&'a str>,
    pub release_mbid: Option<&'a str>,
    pub artist_mbid: Option<&'a str>,
    pub release_date: Option<&'a str>,
    pub genres: Vec<String>,
    pub jellyfin_id: Option<&'a str>,
}

pub struct MusicBrainz {
    fanart: Fanart,
    coverart_url: String,
}

impl MusicBrainz {
    #[must_use]
    pub fn new(config: &Config) -> Self {
        Self {
            fanart: Fanart::new(config),
            coverart_url: config.coverart_url.clone(),
        }
    }

    /// The track item, creating its artist and album as needed. `None`
    /// without a title.
    pub fn resolve(&self, conn: &Connection, input: &TrackInput) -> Result<Option<Item>> {
        let Some(title) = presence(Some(input.title)) else {
            return Ok(None);
        };
        let artist = self.ensure_artist(conn, input.artist_mbid, input.artist)?;
        let album = self.ensure_album(
            conn,
            &AlbumInput {
                title: input.album.unwrap_or_default(),
                artist: input.artist,
                release_mbid: input.release_mbid,
                artist_mbid: input.artist_mbid,
                release_date: input.release_date,
                genres: input.genres.clone(),
                jellyfin_id: input.album_jellyfin_id,
            },
            &artist,
        )?;
        let external_id = track_external_id(input.release_track_mbid).unwrap_or_else(|| {
            synthetic_id(
                "track",
                &format!(
                    "{}/{}/{title}",
                    input.artist.unwrap_or_default(),
                    input.album.unwrap_or_default()
                ),
            )
        });
        let existing = Item::find_by_key(conn, "track", &external_id)?;
        let jellyfin_id = presence(input.jellyfin_id)
            .map(String::from)
            .or_else(|| existing.and_then(|e| e.jellyfin_id));
        let attrs = Attrs::new()
            .text("parent_external_id", Some(album.external_id.clone()))
            .text("title", Some(title))
            .int("runtime", input.length_ms.map(ms_to_minutes))
            .text("poster_path", album.poster_path.clone())
            .text("jellyfin_id", jellyfin_id)
            .metadata(&json!({
                "artist": artist.title,
                "artist_external_id": artist.external_id,
                "album": album.title,
                "album_external_id": album.external_id,
                "length_ms": input.length_ms,
                "track_number": input.track_number,
                "disc_number": input.disc_number,
            }));
        Ok(Some(Item::upsert(conn, "track", &external_id, &attrs)?))
    }

    /// The album item from an album alone, so a discography lists albums
    /// never played. `None` without a title.
    pub fn resolve_album(&self, conn: &Connection, input: &AlbumInput) -> Result<Option<Item>> {
        if presence(Some(input.title)).is_none() {
            return Ok(None);
        }
        let artist = self.ensure_artist(conn, input.artist_mbid, input.artist)?;
        Ok(Some(self.ensure_album(conn, input, &artist)?))
    }

    fn ensure_artist(
        &self,
        conn: &Connection,
        mbid: Option<&str>,
        name: Option<&str>,
    ) -> Result<Item> {
        let name = presence(name).unwrap_or("Unknown Artist");
        let mbid = presence(mbid);
        let external_id = mbid.map_or_else(|| synthetic_id("artist", name), artist_external_id);
        let existing = Item::find_by_key(conn, "artist", &external_id)?;
        let poster = match existing.and_then(|e| e.poster_path) {
            Some(poster) => Some(poster),
            None => self.fanart.artist_image(mbid),
        };
        Item::upsert(
            conn,
            "artist",
            &external_id,
            &Attrs::new()
                .text("title", Some(name))
                .text("poster_path", poster),
        )
    }

    fn ensure_album(&self, conn: &Connection, input: &AlbumInput, artist: &Item) -> Result<Item> {
        let title = presence(Some(input.title)).unwrap_or("Unknown Album");
        let external_id = album_external_id(input.release_mbid)
            .unwrap_or_else(|| synthetic_id("album", &format!("{}/{title}", artist.title)));
        let existing = Item::find_by_key(conn, "album", &external_id)?;

        let mut genres: Vec<Value> = input
            .genres
            .iter()
            .map(|g| g.trim())
            .filter(|g| !g.is_empty())
            .map(|g| Value::String(g.to_string()))
            .collect();
        if genres.is_empty()
            && let Some(Value::Array(kept)) =
                existing.as_ref().and_then(|e| e.metadata.get("genres"))
        {
            genres.clone_from(kept);
        }
        let release_date = presence(input.release_date)
            .map(String::from)
            .or_else(|| existing.as_ref().and_then(|e| e.release_date.clone()));
        let jellyfin_id = presence(input.jellyfin_id)
            .map(String::from)
            .or_else(|| existing.as_ref().and_then(|e| e.jellyfin_id.clone()));
        // Keep fields set outside this path (the release type).
        let mut metadata = existing.map(|e| e.metadata).unwrap_or_default();
        metadata.insert("artist".into(), json!(artist.title));
        metadata.insert("artist_external_id".into(), json!(artist.external_id));
        metadata.insert("genres".into(), Value::Array(genres));

        let poster = presence(input.release_mbid)
            .map(|m| format!("{}/release/{m}/front-250", self.coverart_url));
        let attrs = Attrs::new()
            .text("parent_external_id", Some(artist.external_id.clone()))
            .text("title", Some(title))
            .text("release_date", release_date)
            .text("jellyfin_id", jellyfin_id)
            .text("poster_path", poster)
            .metadata(&Value::Object(metadata));
        Item::upsert(conn, "album", &external_id, &attrs)
    }
}

#[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
fn ms_to_minutes(ms: i64) -> i64 {
    (ms as f64 / 60_000.0).round() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;

    fn mb() -> MusicBrainz {
        MusicBrainz::new(&Config::default())
    }

    #[test]
    fn keys_tagged_music_by_release_and_release_track() {
        let conn = db::open_in_memory().unwrap();
        let track = mb()
            .resolve(
                &conn,
                &TrackInput {
                    title: "Is It a Lie",
                    artist: Some("Bodyjar"),
                    album: Some("Plastic Skies"),
                    release_track_mbid: Some("rt-1"),
                    release_mbid: Some("rel-1"),
                    artist_mbid: Some("art-1"),
                    length_ms: Some(152_000),
                    track_number: Some(1),
                    genres: vec!["punk".into()],
                    jellyfin_id: Some("jf-1"),
                    ..TrackInput::default()
                },
            )
            .unwrap()
            .unwrap();
        assert_eq!(track.external_id, "mbid:rt:rt-1");
        assert_eq!(
            track.parent_external_id.as_deref(),
            Some("mbid:release:rel-1")
        );
        assert_eq!(track.runtime, Some(3));
        assert_eq!(track.artist(), Some("Bodyjar"));
        assert_eq!(track.track_number(), Some(1));
        assert_eq!(
            track.poster_path.as_deref(),
            Some("https://coverartarchive.org/release/rel-1/front-250")
        );
        let album = Item::find_by_key(&conn, "album", "mbid:release:rel-1")
            .unwrap()
            .unwrap();
        assert_eq!(
            album.parent_external_id.as_deref(),
            Some("mbid:artist:art-1")
        );
        assert_eq!(album.genres(), vec!["punk"]);
    }

    #[test]
    fn untagged_music_gets_stable_synthetic_ids() {
        let conn = db::open_in_memory().unwrap();
        let input = TrackInput {
            title: "Song",
            artist: Some("Band"),
            album: Some("Record"),
            ..TrackInput::default()
        };
        let one = mb().resolve(&conn, &input).unwrap().unwrap();
        let two = mb().resolve(&conn, &input).unwrap().unwrap();
        assert_eq!(one.id, two.id);
        assert!(one.external_id.starts_with("mbid:synthetic:track:"));
    }

    #[test]
    fn an_album_keeps_genres_and_release_date_a_track_lacks() {
        let conn = db::open_in_memory().unwrap();
        let base = TrackInput {
            title: "A",
            artist: Some("Band"),
            album: Some("Record"),
            release_mbid: Some("rel"),
            release_date: Some("2012-01-01"),
            genres: vec!["rock".into()],
            ..TrackInput::default()
        };
        mb().resolve(&conn, &base).unwrap();
        mb().resolve(
            &conn,
            &TrackInput {
                title: "B",
                release_date: None,
                genres: vec![],
                ..base.clone()
            },
        )
        .unwrap();
        let album = Item::find_by_key(&conn, "album", "mbid:release:rel")
            .unwrap()
            .unwrap();
        assert_eq!(album.genres(), vec!["rock"]);
        assert_eq!(album.release_date.as_deref(), Some("2012-01-01"));
    }
}
