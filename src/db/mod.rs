//! SQLite access: connection setup, migrations and a small connection pool.
//!
//! SQLite allows one writer at a time. WAL lets reads run alongside the
//! background sync's writes, and `busy_timeout` makes a blocked writer wait
//! instead of failing. Writes stay small and independent: no transaction
//! spans HTTP calls or loops.

use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use rusqlite::{Connection, ErrorCode};

/// Each entry upgrades the schema by one version (`PRAGMA user_version`).
const MIGRATIONS: &[&str] = &[include_str!("schema.sql")];

/// Opens a connection with Rewind's pragmas.
///
/// # Errors
/// When the file can't be opened.
pub fn open(path: &Path, busy_timeout_ms: u64) -> Result<Connection> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    let conn = Connection::open(path).with_context(|| format!("opening {}", path.display()))?;
    configure(&conn, busy_timeout_ms)?;
    Ok(conn)
}

/// An in-memory database with the full schema, for tests.
///
/// # Errors
/// Never in practice.
pub fn open_in_memory() -> Result<Connection> {
    let conn = Connection::open_in_memory()?;
    configure(&conn, 1_000)?;
    migrate(&conn)?;
    Ok(conn)
}

fn configure(conn: &Connection, busy_timeout_ms: u64) -> Result<()> {
    conn.busy_timeout(Duration::from_millis(busy_timeout_ms))?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;",
    )?;
    Ok(())
}

fn version(conn: &Connection) -> Result<usize> {
    let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    Ok(usize::try_from(version).unwrap_or(0))
}

/// How many migrations haven't run yet.
///
/// # Errors
/// When the database is newer than this binary.
pub fn pending(conn: &Connection) -> Result<usize> {
    let current = version(conn)?;
    if current > MIGRATIONS.len() {
        bail!(
            "the database is at schema version {current}, newer than this rewind ({}); upgrade rewind",
            MIGRATIONS.len()
        );
    }
    Ok(MIGRATIONS.len() - current)
}

/// Runs every pending migration, each in its own transaction. Returns how
/// many ran.
///
/// # Errors
/// When a migration fails; it's rolled back.
pub fn migrate(conn: &Connection) -> Result<usize> {
    let pending = pending(conn)?;
    let current = version(conn)?;
    for (index, sql) in MIGRATIONS.iter().enumerate().skip(current) {
        let next = index + 1;
        conn.execute_batch(&format!(
            "BEGIN IMMEDIATE;\n{sql}\nPRAGMA user_version = {next};\nCOMMIT;"
        ))
        .inspect_err(|_| {
            let _ = conn.execute_batch("ROLLBACK");
        })
        .with_context(|| format!("running migration {next}"))?;
    }
    Ok(pending)
}

/// True for SQLite's transient single-writer contention, as opposed to a real
/// database fault that must surface.
#[must_use]
pub fn is_locked(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause.downcast_ref::<rusqlite::Error>().is_some_and(|e| {
            matches!(
                e.sqlite_error_code(),
                Some(ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
            )
        })
    })
}

/// True when the error is a UNIQUE constraint violation.
#[must_use]
pub fn is_unique_violation(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(e, _)
            if e.code == ErrorCode::ConstraintViolation
                && e.extended_code == rusqlite::ffi::SQLITE_CONSTRAINT_UNIQUE
    )
}

/// A small pool of connections to one database file, shared by the web
/// server and the background threads.
#[derive(Clone)]
pub struct Db {
    path: PathBuf,
    busy_timeout_ms: u64,
    idle: Arc<Mutex<Vec<Connection>>>,
}

impl Db {
    /// # Errors
    /// When the database can't be opened.
    pub fn new(path: PathBuf, busy_timeout_ms: u64) -> Result<Self> {
        let first = open(&path, busy_timeout_ms)?;
        Ok(Self {
            path,
            busy_timeout_ms,
            idle: Arc::new(Mutex::new(vec![first])),
        })
    }

    /// Borrows a connection; it goes back to the pool when dropped.
    ///
    /// # Errors
    /// When a new connection can't be opened.
    pub fn get(&self) -> Result<Pooled> {
        let conn = self.idle.lock().expect("pool lock").pop();
        let conn = match conn {
            Some(conn) => conn,
            None => open(&self.path, self.busy_timeout_ms)?,
        };
        Ok(Pooled {
            conn: Some(conn),
            idle: Arc::clone(&self.idle),
        })
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

pub struct Pooled {
    conn: Option<Connection>,
    idle: Arc<Mutex<Vec<Connection>>>,
}

impl Deref for Pooled {
    type Target = Connection;

    fn deref(&self) -> &Connection {
        self.conn.as_ref().expect("connection")
    }
}

impl DerefMut for Pooled {
    fn deref_mut(&mut self) -> &mut Connection {
        self.conn.as_mut().expect("connection")
    }
}

impl Drop for Pooled {
    fn drop(&mut self) {
        if let Some(conn) = self.conn.take()
            && let Ok(mut idle) = self.idle.lock()
            && idle.len() < 8
        {
            idle.push(conn);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_once() {
        let dir = tempfile::tempdir().unwrap();
        let conn = open(&dir.path().join("rewind.db"), 1_000).unwrap();
        assert_eq!(pending(&conn).unwrap(), MIGRATIONS.len());
        assert_eq!(migrate(&conn).unwrap(), MIGRATIONS.len());
        assert_eq!(pending(&conn).unwrap(), 0);
        assert_eq!(migrate(&conn).unwrap(), 0);
    }

    #[test]
    fn refuses_a_newer_database() {
        let conn = open_in_memory().unwrap();
        conn.execute_batch("PRAGMA user_version = 99").unwrap();
        assert!(pending(&conn).is_err());
    }
}
