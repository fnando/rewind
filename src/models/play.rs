use anyhow::Result;
use jiff::Timestamp;
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::time::{self, LocalStamp};

pub const SOURCES: &[&str] = &["manual", "jellyfin"];

/// The media types that make up the "Music" group in history and stats.
pub const MUSIC_MEDIA_TYPES: &[&str] = &["track", "music_video"];

#[derive(Debug, Clone, PartialEq)]
pub struct Play {
    pub id: i64,
    pub user_id: i64,
    pub item_id: i64,
    pub source: String,
    pub source_id: Option<i64>,
    pub instance_id: Option<String>,
    pub source_event_id: Option<String>,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub played_seconds: Option<i64>,
    pub progress: Option<f64>,
    pub local_date: String,
    pub local_time: String,
    pub local_hour: i64,
    pub local_weekday: i64,
    pub utc_offset_minutes: i64,
    pub timezone: String,
    pub client: Option<String>,
    pub device_name: Option<String>,
    pub play_method: Option<String>,
}

pub const COLUMNS: &str = "plays.id, plays.user_id, plays.item_id, plays.source, \
     plays.source_id, plays.instance_id, plays.source_event_id, plays.started_at, \
     plays.ended_at, plays.played_seconds, plays.progress, plays.local_date, \
     plays.local_time, plays.local_hour, plays.local_weekday, plays.utc_offset_minutes, \
     plays.timezone, plays.client, plays.device_name, plays.play_method";

/// A play to record. `timezone` is the user's zone at write time; the local
/// fields are derived from it once and never recomputed.
#[derive(Debug, Clone, Default)]
pub struct NewPlay {
    pub user_id: i64,
    pub item_id: i64,
    pub source: String,
    pub source_id: Option<i64>,
    pub instance_id: Option<String>,
    pub source_event_id: Option<String>,
    pub started_at: Option<Timestamp>,
    pub timing: Timing,
    pub client: Option<String>,
    pub device_name: Option<String>,
    pub play_method: Option<String>,
}

/// How far a play got; updated as the plugin re-sends a session.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Timing {
    pub ended_at: Option<Timestamp>,
    pub played_seconds: Option<i64>,
    pub progress: Option<f64>,
}

impl Play {
    /// Maps a row selected with `COLUMNS`, starting at `offset`.
    ///
    /// # Errors
    /// When a column has the wrong type.
    pub fn from_row_at(row: &Row, offset: usize) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(offset)?,
            user_id: row.get(offset + 1)?,
            item_id: row.get(offset + 2)?,
            source: row.get(offset + 3)?,
            source_id: row.get(offset + 4)?,
            instance_id: row.get(offset + 5)?,
            source_event_id: row.get(offset + 6)?,
            started_at: row.get(offset + 7)?,
            ended_at: row.get(offset + 8)?,
            played_seconds: row.get(offset + 9)?,
            progress: row.get(offset + 10)?,
            local_date: row.get(offset + 11)?,
            local_time: row.get(offset + 12)?,
            local_hour: row.get(offset + 13)?,
            local_weekday: row.get(offset + 14)?,
            utc_offset_minutes: row.get(offset + 15)?,
            timezone: row.get(offset + 16)?,
            client: row.get(offset + 17)?,
            device_name: row.get(offset + 18)?,
            play_method: row.get(offset + 19)?,
        })
    }

    /// # Errors
    /// When a column has the wrong type.
    pub fn from_row(row: &Row) -> rusqlite::Result<Self> {
        Self::from_row_at(row, 0)
    }

    #[must_use]
    pub fn started_at(&self) -> Option<Timestamp> {
        time::parse(&self.started_at)
    }

    /// # Errors
    /// On database failure.
    pub fn find(conn: &Connection, id: i64) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                &format!("SELECT {COLUMNS} FROM plays WHERE id = ?"),
                [id],
                Self::from_row,
            )
            .optional()?)
    }

    /// The play recorded for a plugin record on a server, if any.
    ///
    /// # Errors
    /// On database failure.
    pub fn find_by_event(
        conn: &Connection,
        user_id: i64,
        instance_id: &str,
        source_event_id: &str,
    ) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                &format!(
                    "SELECT {COLUMNS} FROM plays \
                     WHERE user_id = ? AND instance_id = ? AND source_event_id = ?"
                ),
                params![user_id, instance_id, source_event_id],
                Self::from_row,
            )
            .optional()?)
    }

    /// Records a play, freezing where it happened on the user's clock.
    ///
    /// # Errors
    /// On database failure, including a UNIQUE violation for an event that's
    /// already recorded.
    pub fn create(conn: &Connection, new: &NewPlay) -> Result<Self> {
        let started_at = new.started_at.unwrap_or_else(time::now);
        let timezone: String = conn.query_row(
            "SELECT timezone FROM users WHERE id = ?",
            [new.user_id],
            |row| row.get(0),
        )?;
        let local = LocalStamp::new(started_at, &timezone);
        let now = time::format(time::now());
        conn.execute(
            "INSERT INTO plays (user_id, item_id, source, source_id, instance_id, \
             source_event_id, started_at, ended_at, played_seconds, progress, local_date, \
             local_time, local_hour, local_weekday, utc_offset_minutes, timezone, client, \
             device_name, play_method, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                new.user_id,
                new.item_id,
                new.source,
                new.source_id,
                new.instance_id,
                new.source_event_id,
                time::format(started_at),
                new.timing.ended_at.map(time::format),
                new.timing.played_seconds,
                new.timing.progress,
                local.date,
                local.time,
                local.hour,
                local.weekday,
                local.offset_minutes,
                local.timezone,
                new.client,
                new.device_name,
                new.play_method,
                now,
                now
            ],
        )?;
        Ok(Self::find(conn, conn.last_insert_rowid())?.expect("just created"))
    }

    /// Updates how far a play got. The start and local fields never change.
    /// Returns whether anything changed.
    ///
    /// # Errors
    /// On database failure.
    pub fn update_timing(&self, conn: &Connection, timing: &Timing) -> Result<bool> {
        let current = Timing {
            ended_at: self.ended_at.as_deref().and_then(time::parse),
            played_seconds: self.played_seconds,
            progress: self.progress,
        };
        if &current == timing {
            return Ok(false);
        }
        conn.execute(
            "UPDATE plays SET ended_at = ?, played_seconds = ?, progress = ?, updated_at = ? \
             WHERE id = ?",
            params![
                timing.ended_at.map(time::format),
                timing.played_seconds,
                timing.progress,
                time::format(time::now()),
                self.id
            ],
        )?;
        Ok(true)
    }

    /// # Errors
    /// On database failure.
    pub fn delete(conn: &Connection, id: i64) -> Result<()> {
        conn.execute("DELETE FROM plays WHERE id = ?", [id])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use crate::models::User;
    use crate::models::item::{Attrs, Item};

    fn setup() -> (Connection, i64, i64) {
        let conn = db::open_in_memory().unwrap();
        let user = User::create(&conn, "fnando", None, "x").unwrap();
        User::set_timezone(&conn, user.id, "America/Los_Angeles").unwrap();
        let item = Item::upsert(
            &conn,
            "movie",
            "tmdb:1",
            &Attrs::new().text("title", Some("M")),
        )
        .unwrap();
        (conn, user.id, item.id)
    }

    #[test]
    fn freezes_the_local_time_at_write() {
        let (conn, user_id, item_id) = setup();
        let play = Play::create(
            &conn,
            &NewPlay {
                user_id,
                item_id,
                source: "manual".into(),
                started_at: Some("2026-10-31T04:15:00Z".parse().unwrap()),
                ..NewPlay::default()
            },
        )
        .unwrap();
        assert_eq!(play.local_date, "2026-10-30");
        assert_eq!(play.local_time, "21:15");
        assert_eq!(play.local_hour, 21);
        assert_eq!(play.utc_offset_minutes, -420);
        assert_eq!(play.timezone, "America/Los_Angeles");

        // Moving zones later doesn't rewrite it.
        User::set_timezone(&conn, user_id, "Asia/Tokyo").unwrap();
        let again = Play::find(&conn, play.id).unwrap().unwrap();
        assert_eq!(again.local_hour, 21);
        assert_eq!(again.local_date, "2026-10-30");
    }

    #[test]
    fn updates_timing_only_when_it_changed() {
        let (conn, user_id, item_id) = setup();
        let play = Play::create(
            &conn,
            &NewPlay {
                user_id,
                item_id,
                source: "jellyfin".into(),
                instance_id: Some("s".into()),
                source_event_id: Some("rewind:1".into()),
                ..NewPlay::default()
            },
        )
        .unwrap();
        let timing = Timing {
            ended_at: Some("2026-11-09T16:44:34Z".parse().unwrap()),
            played_seconds: Some(152),
            progress: Some(100.0),
        };
        assert!(play.update_timing(&conn, &timing).unwrap());
        let play = Play::find(&conn, play.id).unwrap().unwrap();
        assert_eq!(play.played_seconds, Some(152));
        assert!(!play.update_timing(&conn, &timing).unwrap());
    }
}
