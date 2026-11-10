//! Music videos: Jellyfin-native items (no provider knows them) linked to
//! their artist by name.

use anyhow::Result;
use rusqlite::Connection;
use serde_json::json;

use crate::models::item::{Attrs, Item};

/// The artist item whose title matches `name` (case-insensitive, trimmed).
pub fn artist_item_for(conn: &Connection, name: Option<&str>) -> Result<Option<Item>> {
    let normalized = name.unwrap_or_default().trim().to_lowercase();
    if normalized.is_empty() {
        return Ok(None);
    }
    Item::first(
        conn,
        "WHERE media_type = 'artist' AND lower(title) = ? ORDER BY id",
        [normalized],
    )
}

#[derive(Debug, Clone, Default)]
pub struct VideoInput<'a> {
    pub external_id: &'a str,
    pub title: &'a str,
    pub artist_name: Option<&'a str>,
    pub runtime: Option<i64>,
    pub release_date: Option<&'a str>,
    pub poster_path: Option<&'a str>,
    pub jellyfin_id: Option<&'a str>,
}

/// Upserts the music video. When the artist resolves, the video is parented
/// under it so it shows on the artist page.
pub fn build(conn: &Connection, input: &VideoInput) -> Result<Item> {
    let artist = artist_item_for(conn, input.artist_name)?;
    let artist_external_id = artist.map(|a| a.external_id);
    let mut attrs = Attrs::new()
        .text("title", Some(input.title))
        .text("parent_external_id", artist_external_id.clone())
        .text("release_date", input.release_date)
        .int("runtime", input.runtime)
        .text("poster_path", input.poster_path)
        .metadata(&json!({
            "artist": input.artist_name,
            "artist_external_id": artist_external_id,
            "source": "jellyfin",
        }));
    // Only set the id when known, so a later build never clears it.
    if let Some(id) = input.jellyfin_id {
        attrs = attrs.text("jellyfin_id", Some(id));
    }
    Item::upsert(conn, "music_video", input.external_id, &attrs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;

    #[test]
    fn links_to_a_matching_artist_or_keeps_the_name_as_text() {
        let conn = db::open_in_memory().unwrap();
        Item::upsert(
            &conn,
            "artist",
            "mbid:artist:a",
            &Attrs::new().text("title", Some("Bodyjar")),
        )
        .unwrap();
        let linked = build(
            &conn,
            &VideoInput {
                external_id: "jellyfin:v1",
                title: "Video",
                artist_name: Some("  bodyjar "),
                jellyfin_id: Some("v1"),
                ..VideoInput::default()
            },
        )
        .unwrap();
        assert_eq!(linked.parent_external_id.as_deref(), Some("mbid:artist:a"));
        assert_eq!(linked.meta_str("artist_external_id"), Some("mbid:artist:a"));

        let loose = build(
            &conn,
            &VideoInput {
                external_id: "jellyfin:v2",
                title: "Other",
                artist_name: Some("Nobody"),
                ..VideoInput::default()
            },
        )
        .unwrap();
        assert_eq!(loose.parent_external_id, None);
        assert_eq!(loose.artist(), Some("Nobody"));

        // Re-building keeps the stored Jellyfin id.
        let again = build(
            &conn,
            &VideoInput {
                external_id: "jellyfin:v1",
                title: "Video 2",
                artist_name: Some("Bodyjar"),
                ..VideoInput::default()
            },
        )
        .unwrap();
        assert_eq!(again.id, linked.id);
        assert_eq!(again.jellyfin_id.as_deref(), Some("v1"));
    }
}
