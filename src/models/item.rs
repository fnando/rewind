use anyhow::Result;
use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OptionalExtension, Row, params_from_iter};
use serde_json::{Map, Value};

use crate::time;

pub const MEDIA_TYPES: &[&str] = &[
    "movie",
    "episode",
    "series",
    "track",
    "album",
    "artist",
    "music_video",
];

/// Something that can be played or browsed: a movie, episode, series, track,
/// album, artist or music video. Unique on `(media_type, external_id)`.
#[derive(Debug, Clone, PartialEq)]
pub struct Item {
    pub id: i64,
    pub media_type: String,
    pub external_id: String,
    pub parent_external_id: Option<String>,
    pub season_number: Option<i64>,
    pub episode_number: Option<i64>,
    pub title: String,
    pub overview: Option<String>,
    pub release_date: Option<String>,
    pub poster_path: Option<String>,
    pub runtime: Option<i64>,
    pub metadata: Map<String, Value>,
    pub jellyfin_id: Option<String>,
    pub source_etag: Option<String>,
    pub fetched_at: String,
}

pub const COLUMNS: &str = "items.id, items.media_type, items.external_id, \
     items.parent_external_id, items.season_number, items.episode_number, items.title, \
     items.overview, items.release_date, items.poster_path, items.runtime, \
     items.metadata_json, items.jellyfin_id, items.source_etag, items.fetched_at";

/// The columns an upsert writes. Only the columns that are set are touched,
/// so an update keeps everything else.
#[derive(Debug, Default, Clone)]
pub struct Attrs(Vec<(&'static str, SqlValue)>);

impl Attrs {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn text(mut self, column: &'static str, value: Option<impl Into<String>>) -> Self {
        let value = value.map_or(SqlValue::Null, |v| SqlValue::Text(v.into()));
        self.0.push((column, value));
        self
    }

    #[must_use]
    pub fn int(mut self, column: &'static str, value: Option<i64>) -> Self {
        self.0
            .push((column, value.map_or(SqlValue::Null, SqlValue::Integer)));
        self
    }

    #[must_use]
    pub fn metadata(mut self, value: &Value) -> Self {
        self.0
            .push(("metadata_json", SqlValue::Text(value.to_string())));
        self
    }
}

impl Item {
    /// Maps a row selected with `COLUMNS`, starting at `offset`.
    ///
    /// # Errors
    /// When a column has the wrong type.
    pub fn from_row_at(row: &Row, offset: usize) -> rusqlite::Result<Self> {
        let metadata: Option<String> = row.get(offset + 11)?;
        Ok(Self {
            id: row.get(offset)?,
            media_type: row.get(offset + 1)?,
            external_id: row.get(offset + 2)?,
            parent_external_id: row.get(offset + 3)?,
            season_number: row.get(offset + 4)?,
            episode_number: row.get(offset + 5)?,
            title: row.get(offset + 6)?,
            overview: row.get(offset + 7)?,
            release_date: row.get(offset + 8)?,
            poster_path: row.get(offset + 9)?,
            runtime: row.get(offset + 10)?,
            metadata: metadata
                .and_then(|m| serde_json::from_str(&m).ok())
                .unwrap_or_default(),
            jellyfin_id: row.get(offset + 12)?,
            source_etag: row.get(offset + 13)?,
            fetched_at: row.get(offset + 14)?,
        })
    }

    /// # Errors
    /// When a column has the wrong type.
    pub fn from_row(row: &Row) -> rusqlite::Result<Self> {
        Self::from_row_at(row, 0)
    }

    /// A metadata string value.
    #[must_use]
    pub fn meta_str(&self, key: &str) -> Option<&str> {
        self.metadata
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
    }

    #[must_use]
    pub fn meta_i64(&self, key: &str) -> Option<i64> {
        self.metadata.get(key).and_then(Value::as_i64)
    }

    /// The numeric TMDB id inside `external_id` ("tmdb:603").
    #[must_use]
    pub fn tmdb_id(&self) -> Option<i64> {
        tmdb_number(Some(&self.external_id))
    }

    #[must_use]
    pub fn parent_tmdb_id(&self) -> Option<i64> {
        tmdb_number(self.parent_external_id.as_deref())
    }

    #[must_use]
    pub fn mbid(&self) -> Option<&str> {
        self.external_id.strip_prefix("mbid:")
    }

    /// Genre names, whether stored as TMDB objects or plain strings.
    #[must_use]
    pub fn genres(&self) -> Vec<String> {
        self.metadata
            .get("genres")
            .and_then(Value::as_array)
            .map(|genres| {
                genres
                    .iter()
                    .filter_map(|g| match g {
                        Value::String(name) => Some(name.clone()),
                        Value::Object(map) => {
                            map.get("name").and_then(Value::as_str).map(String::from)
                        }
                        _ => None,
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    #[must_use]
    pub fn credits(&self) -> Option<&Map<String, Value>> {
        self.metadata.get("credits").and_then(Value::as_object)
    }

    #[must_use]
    pub fn artist(&self) -> Option<&str> {
        self.meta_str("artist")
    }

    #[must_use]
    pub fn album(&self) -> Option<&str> {
        self.meta_str("album")
    }

    #[must_use]
    pub fn track_number(&self) -> Option<i64> {
        self.meta_i64("track_number")
    }

    #[must_use]
    pub fn disc_number(&self) -> Option<i64> {
        self.meta_i64("disc_number")
    }

    /// A stable key for ratings and reviews: the Jellyfin id when known,
    /// else `(media_type, external_id)`, which a rebuild reproduces.
    #[must_use]
    pub fn rating_key(&self) -> String {
        match &self.jellyfin_id {
            Some(id) => format!("jellyfin:{id}"),
            None => format!("{}:{}", self.media_type, self.external_id),
        }
    }

    #[must_use]
    pub fn display_title(&self) -> String {
        match self.media_type.as_str() {
            "episode" => format!(
                "{} S{:02}E{:02} · {}",
                self.meta_str("series_name").unwrap_or_default(),
                self.season_number.unwrap_or(0),
                self.episode_number.unwrap_or(0),
                self.title
            ),
            "track" | "music_video" => match self.artist() {
                Some(artist) => format!("{artist} — {}", self.title),
                None => self.title.clone(),
            },
            _ => self.title.clone(),
        }
    }

    /// # Errors
    /// On database failure.
    pub fn find(conn: &Connection, id: i64) -> Result<Option<Self>> {
        Self::first(conn, "WHERE id = ?", [id])
    }

    /// # Errors
    /// On database failure.
    pub fn find_by_key(
        conn: &Connection,
        media_type: &str,
        external_id: &str,
    ) -> Result<Option<Self>> {
        Self::first(
            conn,
            "WHERE media_type = ? AND external_id = ?",
            [media_type, external_id],
        )
    }

    /// # Errors
    /// On database failure.
    pub fn find_by_jellyfin_id(conn: &Connection, jellyfin_id: &str) -> Result<Option<Self>> {
        Self::first(conn, "WHERE jellyfin_id = ? ORDER BY id", [jellyfin_id])
    }

    /// The first item matching a `WHERE …` tail.
    ///
    /// # Errors
    /// On database failure.
    pub fn first<P: rusqlite::Params>(
        conn: &Connection,
        tail: &str,
        params: P,
    ) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                &format!("SELECT {COLUMNS} FROM items {tail} LIMIT 1"),
                params,
                Self::from_row,
            )
            .optional()?)
    }

    /// Every item matching a `WHERE …` tail.
    ///
    /// # Errors
    /// On database failure.
    pub fn list<P: rusqlite::Params>(
        conn: &Connection,
        tail: &str,
        params: P,
    ) -> Result<Vec<Self>> {
        let mut stmt = conn.prepare(&format!("SELECT {COLUMNS} FROM items {tail}"))?;
        let rows = stmt.query_map(params, Self::from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Inserts the item, or updates the set columns of the existing one.
    /// `fetched_at` is always refreshed.
    ///
    /// # Errors
    /// On database failure.
    pub fn upsert(
        conn: &Connection,
        media_type: &str,
        external_id: &str,
        attrs: &Attrs,
    ) -> Result<Self> {
        let now = time::format(time::now());
        let existing = Self::find_by_key(conn, media_type, external_id)?;
        let id = if let Some(existing) = existing {
            let mut sets: Vec<String> = attrs.0.iter().map(|(c, _)| format!("{c} = ?")).collect();
            sets.push("fetched_at = ?".into());
            sets.push("updated_at = ?".into());
            let mut values: Vec<SqlValue> = attrs.0.iter().map(|(_, v)| v.clone()).collect();
            values.push(SqlValue::Text(now.clone()));
            values.push(SqlValue::Text(now));
            values.push(SqlValue::Integer(existing.id));
            conn.execute(
                &format!("UPDATE items SET {} WHERE id = ?", sets.join(", ")),
                params_from_iter(values),
            )?;
            existing.id
        } else {
            let mut columns = vec!["media_type", "external_id"];
            let mut values = vec![
                SqlValue::Text(media_type.into()),
                SqlValue::Text(external_id.into()),
            ];
            for (column, value) in &attrs.0 {
                columns.push(column);
                values.push(value.clone());
            }
            if !columns.contains(&"title") {
                columns.push("title");
                values.push(SqlValue::Text(String::new()));
            }
            columns.extend(["fetched_at", "created_at", "updated_at"]);
            values.extend([
                SqlValue::Text(now.clone()),
                SqlValue::Text(now.clone()),
                SqlValue::Text(now),
            ]);
            let marks = vec!["?"; columns.len()].join(", ");
            conn.execute(
                &format!(
                    "INSERT INTO items ({}) VALUES ({marks})",
                    columns.join(", ")
                ),
                params_from_iter(values),
            )?;
            conn.last_insert_rowid()
        };
        Ok(Self::find(conn, id)?.expect("just written"))
    }

    /// Updates columns of an existing item by id.
    ///
    /// # Errors
    /// On database failure.
    pub fn update(conn: &Connection, id: i64, attrs: &Attrs) -> Result<()> {
        if attrs.0.is_empty() {
            return Ok(());
        }
        let mut sets: Vec<String> = attrs.0.iter().map(|(c, _)| format!("{c} = ?")).collect();
        sets.push("updated_at = ?".into());
        let mut values: Vec<SqlValue> = attrs.0.iter().map(|(_, v)| v.clone()).collect();
        values.push(SqlValue::Text(time::format(time::now())));
        values.push(SqlValue::Integer(id));
        conn.execute(
            &format!("UPDATE items SET {} WHERE id = ?", sets.join(", ")),
            params_from_iter(values),
        )?;
        Ok(())
    }
}

fn tmdb_number(value: Option<&str>) -> Option<i64> {
    value?.strip_prefix("tmdb:")?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use serde_json::json;

    #[test]
    fn upsert_inserts_then_updates_only_the_given_columns() {
        let conn = db::open_in_memory().unwrap();
        let item = Item::upsert(
            &conn,
            "movie",
            "tmdb:603",
            &Attrs::new()
                .text("title", Some("The Matrix"))
                .text("overview", Some("Neo"))
                .metadata(&json!({"genres": [{"name": "Action"}, "Sci-Fi"]})),
        )
        .unwrap();
        assert_eq!(item.tmdb_id(), Some(603));
        assert_eq!(item.genres(), vec!["Action", "Sci-Fi"]);
        assert_eq!(item.rating_key(), "movie:tmdb:603");

        let again = Item::upsert(
            &conn,
            "movie",
            "tmdb:603",
            &Attrs::new().text("title", Some("Matrix")),
        )
        .unwrap();
        assert_eq!(again.id, item.id);
        assert_eq!(again.title, "Matrix");
        assert_eq!(again.overview.as_deref(), Some("Neo"));
    }

    #[test]
    fn display_titles() {
        let conn = db::open_in_memory().unwrap();
        let episode = Item::upsert(
            &conn,
            "episode",
            "tmdb:1",
            &Attrs::new()
                .text("title", Some("Pilot"))
                .int("season_number", Some(1))
                .int("episode_number", Some(2))
                .metadata(&json!({"series_name": "Lost"})),
        )
        .unwrap();
        assert_eq!(episode.display_title(), "Lost S01E02 · Pilot");

        let track = Item::upsert(
            &conn,
            "track",
            "mbid:rt:x",
            &Attrs::new()
                .text("title", Some("Is It a Lie"))
                .metadata(&json!({"artist": "Bodyjar"})),
        )
        .unwrap();
        assert_eq!(track.display_title(), "Bodyjar — Is It a Lie");
    }
}
