use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::{crypto, time};

/// A user's connection to a Jellyfin server account, holding the encrypted
/// access token and the plugin feed cursor.
#[derive(Debug, Clone, PartialEq)]
pub struct Source {
    pub id: i64,
    pub user_id: i64,
    pub kind: String,
    pub url: String,
    pub external_user_id: String,
    pub external_user_name: Option<String>,
    pub instance_id: String,
    pub credentials: String,
    pub cursor: Option<String>,
    pub enabled: bool,
    pub last_synced_at: Option<String>,
    pub last_error_id: Option<i64>,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceError {
    pub id: i64,
    pub source_id: i64,
    pub message: String,
    pub created_at: String,
}

pub struct NewSource<'a> {
    pub user_id: i64,
    pub url: &'a str,
    pub external_user_id: &'a str,
    pub external_user_name: Option<&'a str>,
    pub instance_id: &'a str,
    pub access_token: &'a str,
}

const COLUMNS: &str = "id, user_id, type, url, external_user_id, external_user_name, \
     instance_id, credentials, cursor, enabled, last_synced_at, last_error_id, created_at";

/// Trims whitespace and trailing slashes from a server URL.
#[must_use]
pub fn normalize_url(value: &str) -> String {
    value.trim().trim_end_matches('/').to_string()
}

impl Source {
    fn from_row(row: &Row) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            user_id: row.get(1)?,
            kind: row.get(2)?,
            url: row.get(3)?,
            external_user_id: row.get(4)?,
            external_user_name: row.get(5)?,
            instance_id: row.get(6)?,
            credentials: row.get(7)?,
            cursor: row.get(8)?,
            enabled: row.get(9)?,
            last_synced_at: row.get(10)?,
            last_error_id: row.get(11)?,
            created_at: row.get(12)?,
        })
    }

    /// The decrypted access token.
    ///
    /// # Errors
    /// When it was encrypted with another key.
    pub fn access_token(&self, key: &[u8; 32]) -> Result<String> {
        crypto::decrypt(key, &self.credentials)
    }

    /// The stored feed cursor as a sequence number (0 when unset).
    #[must_use]
    pub fn since(&self) -> i64 {
        self.cursor
            .as_deref()
            .and_then(|c| c.parse().ok())
            .unwrap_or(0)
    }

    /// Who this connection signs in as.
    #[must_use]
    pub fn account_label(&self) -> &str {
        self.external_user_name
            .as_deref()
            .unwrap_or(&self.external_user_id)
    }

    /// # Errors
    /// On database failure.
    pub fn find(conn: &Connection, id: i64) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                &format!("SELECT {COLUMNS} FROM sources WHERE id = ?"),
                [id],
                Self::from_row,
            )
            .optional()?)
    }

    /// # Errors
    /// On database failure.
    pub fn all(conn: &Connection) -> Result<Vec<Self>> {
        query(conn, "ORDER BY user_id, type, url", [])
    }

    /// # Errors
    /// On database failure.
    pub fn enabled(conn: &Connection) -> Result<Vec<Self>> {
        query(conn, "WHERE enabled = 1 ORDER BY id", [])
    }

    /// # Errors
    /// On database failure.
    pub fn for_user(conn: &Connection, user_id: i64) -> Result<Vec<Self>> {
        query(conn, "WHERE user_id = ? ORDER BY created_at, id", [user_id])
    }

    /// Stores a new connection with its token encrypted.
    ///
    /// # Errors
    /// When the account is already connected for this user, or on database
    /// failure.
    pub fn create(conn: &Connection, key: &[u8; 32], new: &NewSource) -> Result<Self> {
        let now = time::format(time::now());
        conn.execute(
            "INSERT INTO sources (user_id, type, url, external_user_id, external_user_name, \
             instance_id, credentials, created_at, updated_at) \
             VALUES (?, 'jellyfin', ?, ?, ?, ?, ?, ?, ?)",
            params![
                new.user_id,
                normalize_url(new.url),
                new.external_user_id,
                new.external_user_name,
                new.instance_id,
                crypto::encrypt(key, new.access_token)?,
                now,
                now
            ],
        )?;
        Ok(Self::find(conn, conn.last_insert_rowid())?.expect("just created"))
    }

    /// # Errors
    /// On database failure.
    pub fn set_enabled(conn: &Connection, id: i64, enabled: bool) -> Result<()> {
        conn.execute(
            "UPDATE sources SET enabled = ?, updated_at = ? WHERE id = ?",
            params![enabled, time::format(time::now()), id],
        )?;
        Ok(())
    }

    /// # Errors
    /// On database failure.
    pub fn set_user_name(conn: &Connection, id: i64, name: &str) -> Result<()> {
        conn.execute(
            "UPDATE sources SET external_user_name = ?, updated_at = ? WHERE id = ?",
            params![name, time::format(time::now()), id],
        )?;
        Ok(())
    }

    /// Saves a fully applied feed page: moves the cursor and clears the
    /// current error.
    ///
    /// # Errors
    /// On database failure.
    pub fn save_cursor(conn: &Connection, id: i64, cursor: Option<i64>) -> Result<()> {
        conn.execute(
            "UPDATE sources SET cursor = ?, last_synced_at = ?, last_error_id = NULL \
             WHERE id = ?",
            params![cursor.map(|c| c.to_string()), time::format(time::now()), id],
        )?;
        Ok(())
    }

    /// Forgets the feed position so the next sync re-reads everything.
    ///
    /// # Errors
    /// On database failure.
    pub fn clear_cursor(conn: &Connection, id: i64) -> Result<()> {
        conn.execute("UPDATE sources SET cursor = NULL WHERE id = ?", [id])?;
        Ok(())
    }

    /// Appends a sync failure to the source's log and marks it current.
    ///
    /// # Errors
    /// On database failure.
    pub fn record_error(conn: &Connection, id: i64, message: &str) -> Result<i64> {
        let message: String = message.chars().take(500).collect();
        conn.execute(
            "INSERT INTO source_errors (source_id, message, created_at) VALUES (?, ?, ?)",
            params![id, message, time::format(time::now())],
        )?;
        let error_id = conn.last_insert_rowid();
        conn.execute(
            "UPDATE sources SET last_error_id = ? WHERE id = ?",
            params![error_id, id],
        )?;
        Ok(error_id)
    }

    /// The current, unresolved sync error.
    ///
    /// # Errors
    /// On database failure.
    pub fn current_error(&self, conn: &Connection) -> Result<Option<SourceError>> {
        let Some(error_id) = self.last_error_id else {
            return Ok(None);
        };
        SourceError::find(conn, error_id)
    }

    /// The most recent error ever recorded, resolved or not.
    ///
    /// # Errors
    /// On database failure.
    pub fn latest_error(&self, conn: &Connection) -> Result<Option<SourceError>> {
        Ok(conn
            .query_row(
                "SELECT id, source_id, message, created_at FROM source_errors \
                 WHERE source_id = ? ORDER BY created_at DESC, id DESC LIMIT 1",
                [self.id],
                SourceError::from_row,
            )
            .optional()?)
    }

    /// # Errors
    /// On database failure.
    pub fn delete(conn: &Connection, id: i64) -> Result<()> {
        conn.execute("DELETE FROM sources WHERE id = ?", [id])?;
        Ok(())
    }
}

impl SourceError {
    fn from_row(row: &Row) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            source_id: row.get(1)?,
            message: row.get(2)?,
            created_at: row.get(3)?,
        })
    }

    /// # Errors
    /// On database failure.
    pub fn find(conn: &Connection, id: i64) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                "SELECT id, source_id, message, created_at FROM source_errors WHERE id = ?",
                [id],
                Self::from_row,
            )
            .optional()?)
    }
}

fn query<P: rusqlite::Params>(conn: &Connection, tail: &str, params: P) -> Result<Vec<Source>> {
    let mut stmt = conn.prepare(&format!("SELECT {COLUMNS} FROM sources {tail}"))?;
    let rows = stmt.query_map(params, Source::from_row)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use crate::models::User;

    #[test]
    fn stores_the_token_encrypted() {
        let conn = db::open_in_memory().unwrap();
        let user = User::create(&conn, "fnando", None, "x").unwrap();
        let key = [3u8; 32];
        let source = Source::create(
            &conn,
            &key,
            &NewSource {
                user_id: user.id,
                url: " http://jellyfin:8096/ ",
                external_user_id: "u1",
                external_user_name: Some("fnando"),
                instance_id: "server-1",
                access_token: "tok",
            },
        )
        .unwrap();
        assert_eq!(source.url, "http://jellyfin:8096");
        assert_ne!(source.credentials, "tok");
        assert_eq!(source.access_token(&key).unwrap(), "tok");
        assert_eq!(source.since(), 0);
        assert!(source.enabled);
    }

    #[test]
    fn keeps_an_error_log() {
        let conn = db::open_in_memory().unwrap();
        let user = User::create(&conn, "fnando", None, "x").unwrap();
        let source = Source::create(
            &conn,
            &[3u8; 32],
            &NewSource {
                user_id: user.id,
                url: "http://j",
                external_user_id: "u1",
                external_user_name: None,
                instance_id: "s",
                access_token: "t",
            },
        )
        .unwrap();
        Source::record_error(&conn, source.id, "boom").unwrap();
        let source = Source::find(&conn, source.id).unwrap().unwrap();
        assert_eq!(
            source.current_error(&conn).unwrap().unwrap().message,
            "boom"
        );

        Source::save_cursor(&conn, source.id, Some(42)).unwrap();
        let source = Source::find(&conn, source.id).unwrap().unwrap();
        assert!(source.current_error(&conn).unwrap().is_none());
        assert_eq!(source.latest_error(&conn).unwrap().unwrap().message, "boom");
        assert_eq!(source.since(), 42);
    }
}
