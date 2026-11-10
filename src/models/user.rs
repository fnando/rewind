use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, Row, params};

use super::Invalid;
use crate::time;

pub const RATING_STYLES: &[&str] = &["stars", "thumbs"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct User {
    pub id: i64,
    pub username: String,
    pub name: Option<String>,
    pub password_digest: String,
    pub must_change_password: bool,
    pub rating_style: String,
    pub timezone: String,
    pub admin: bool,
    pub last_login_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

const COLUMNS: &str = "id, username, name, password_digest, must_change_password, \
     rating_style, timezone, admin, last_login_at, created_at, updated_at";

impl User {
    fn from_row(row: &Row) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            username: row.get(1)?,
            name: row.get(2)?,
            password_digest: row.get(3)?,
            must_change_password: row.get(4)?,
            rating_style: row.get(5)?,
            timezone: row.get(6)?,
            admin: row.get(7)?,
            last_login_at: row.get(8)?,
            created_at: row.get(9)?,
            updated_at: row.get(10)?,
        })
    }

    /// The name to greet the user by.
    #[must_use]
    pub fn display_name(&self) -> &str {
        self.name
            .as_deref()
            .filter(|n| !n.trim().is_empty())
            .unwrap_or(&self.username)
    }

    /// # Errors
    /// On database failure.
    pub fn find(conn: &Connection, id: i64) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                &format!("SELECT {COLUMNS} FROM users WHERE id = ?"),
                [id],
                Self::from_row,
            )
            .optional()?)
    }

    /// # Errors
    /// On database failure.
    pub fn find_by_username(conn: &Connection, username: &str) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                &format!("SELECT {COLUMNS} FROM users WHERE username = ? COLLATE NOCASE"),
                [username],
                Self::from_row,
            )
            .optional()?)
    }

    /// # Errors
    /// On database failure.
    pub fn all(conn: &Connection) -> Result<Vec<Self>> {
        let mut stmt = conn.prepare(&format!("SELECT {COLUMNS} FROM users ORDER BY username"))?;
        let rows = stmt.query_map([], Self::from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Creates a user who must change the given password on first login. The
    /// first user owns the instance and is made admin.
    ///
    /// # Errors
    /// When the fields are invalid or the username is taken.
    pub fn create(
        conn: &Connection,
        username: &str,
        name: Option<&str>,
        password: &str,
    ) -> Result<Self> {
        validate_username(username)?;
        if Self::find_by_username(conn, username)?.is_some() {
            return Err(Invalid(vec!["username is already taken".into()]).into());
        }
        let now = time::format(time::now());
        let first: bool =
            conn.query_row("SELECT NOT EXISTS (SELECT 1 FROM users)", [], |r| r.get(0))?;
        conn.execute(
            "INSERT INTO users (username, name, password_digest, must_change_password, admin, \
             created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?, ?)",
            params![username, name, hash_password(password)?, first, now, now],
        )?;
        Ok(Self::find(conn, conn.last_insert_rowid())?.expect("just created"))
    }

    /// Checks a password against the stored hash.
    #[must_use]
    pub fn authenticate(&self, password: &str) -> bool {
        !self.password_digest.is_empty()
            && bcrypt::verify(password, &self.password_digest).unwrap_or(false)
    }

    /// # Errors
    /// On database failure.
    pub fn set_password(
        conn: &Connection,
        id: i64,
        password: &str,
        must_change: bool,
    ) -> Result<()> {
        conn.execute(
            "UPDATE users SET password_digest = ?, must_change_password = ?, updated_at = ? \
             WHERE id = ?",
            params![
                hash_password(password)?,
                must_change,
                time::format(time::now()),
                id
            ],
        )?;
        Ok(())
    }

    /// # Errors
    /// On database failure.
    pub fn set_name(conn: &Connection, id: i64, name: Option<&str>) -> Result<()> {
        conn.execute(
            "UPDATE users SET name = ?, updated_at = ? WHERE id = ?",
            params![name, time::format(time::now()), id],
        )?;
        Ok(())
    }

    /// # Errors
    /// When the style isn't one of `RATING_STYLES`.
    pub fn set_rating_style(conn: &Connection, id: i64, style: &str) -> Result<()> {
        if !RATING_STYLES.contains(&style) {
            return Err(Invalid(vec!["rating_style must be stars or thumbs".into()]).into());
        }
        conn.execute(
            "UPDATE users SET rating_style = ?, updated_at = ? WHERE id = ?",
            params![style, time::format(time::now()), id],
        )?;
        Ok(())
    }

    /// # Errors
    /// When the zone isn't a known IANA name.
    pub fn set_timezone(conn: &Connection, id: i64, timezone: &str) -> Result<()> {
        if !time::is_zone(timezone) {
            return Err(Invalid(vec!["timezone is not a valid IANA timezone".into()]).into());
        }
        conn.execute(
            "UPDATE users SET timezone = ?, updated_at = ? WHERE id = ?",
            params![timezone, time::format(time::now()), id],
        )?;
        Ok(())
    }

    /// # Errors
    /// On database failure.
    pub fn set_admin(conn: &Connection, id: i64, admin: bool) -> Result<()> {
        conn.execute(
            "UPDATE users SET admin = ?, updated_at = ? WHERE id = ?",
            params![admin, time::format(time::now()), id],
        )?;
        Ok(())
    }

    /// # Errors
    /// On database failure.
    pub fn touch_login(conn: &Connection, id: i64) -> Result<()> {
        conn.execute(
            "UPDATE users SET last_login_at = ? WHERE id = ?",
            params![time::format(time::now()), id],
        )?;
        Ok(())
    }

    /// Deletes the user and, through the foreign keys, everything they own.
    ///
    /// # Errors
    /// On database failure.
    pub fn delete(conn: &Connection, id: i64) -> Result<()> {
        conn.execute("DELETE FROM users WHERE id = ?", [id])?;
        Ok(())
    }
}

fn hash_password(password: &str) -> Result<String> {
    // Debug builds (tests) use the minimum cost so suites stay fast; release
    // builds use bcrypt's default.
    let cost = if cfg!(debug_assertions) {
        4
    } else {
        bcrypt::DEFAULT_COST
    };
    Ok(bcrypt::hash(password, cost)?)
}

fn validate_username(username: &str) -> Result<()> {
    let bytes = username.as_bytes();
    let valid = !bytes.is_empty()
        && bytes.len() <= 31
        && bytes[0].is_ascii_alphanumeric()
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-');
    if valid {
        Ok(())
    } else if username.trim().is_empty() {
        Err(Invalid(vec!["username is required".into()]).into())
    } else {
        Err(Invalid(vec!["username must be url-safe".into()]).into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;

    #[test]
    fn creates_and_authenticates() {
        let conn = db::open_in_memory().unwrap();
        let user = User::create(&conn, "fnando", Some("Nando"), "secret-pass").unwrap();
        assert!(user.must_change_password);
        assert_eq!(user.timezone, "UTC");
        assert_eq!(user.rating_style, "stars");
        assert!(user.authenticate("secret-pass"));
        assert!(!user.authenticate("nope"));
        assert_eq!(user.display_name(), "Nando");
        assert!(user.admin, "the first user owns the instance");
        let second = User::create(&conn, "other", None, "x").unwrap();
        assert!(!second.admin);
    }

    #[test]
    fn usernames_are_unique_and_url_safe() {
        let conn = db::open_in_memory().unwrap();
        User::create(&conn, "fnando", None, "x").unwrap();
        assert!(User::create(&conn, "FNANDO", None, "x").is_err());
        assert!(User::create(&conn, "no spaces", None, "x").is_err());
        assert!(User::create(&conn, "-dash", None, "x").is_err());
        assert!(User::create(&conn, "", None, "x").is_err());
    }

    #[test]
    fn rejects_unknown_timezones() {
        let conn = db::open_in_memory().unwrap();
        let user = User::create(&conn, "fnando", None, "x").unwrap();
        assert!(User::set_timezone(&conn, user.id, "Mars/Base").is_err());
        User::set_timezone(&conn, user.id, "America/Sao_Paulo").unwrap();
        let user = User::find(&conn, user.id).unwrap().unwrap();
        assert_eq!(user.timezone, "America/Sao_Paulo");
    }
}
