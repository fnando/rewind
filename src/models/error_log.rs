use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde_json::{Map, Value};

use crate::time;

/// One captured error with the data that caused it, shown on the admin
/// errors page.
#[derive(Debug, Clone, PartialEq)]
pub struct ErrorLog {
    pub id: i64,
    pub error_class: String,
    pub message: String,
    pub backtrace: Option<String>,
    pub context: Map<String, Value>,
    pub created_at: String,
}

impl ErrorLog {
    fn from_row(row: &Row) -> rusqlite::Result<Self> {
        let context: Option<String> = row.get(4)?;
        Ok(Self {
            id: row.get(0)?,
            error_class: row.get(1)?,
            message: row.get(2)?,
            backtrace: row.get(3)?,
            context: context
                .and_then(|c| serde_json::from_str(&c).ok())
                .unwrap_or_default(),
            created_at: row.get(5)?,
        })
    }

    /// Persists an error. Never fails: a logging problem must not mask the
    /// original error, so it's only traced.
    pub fn record(conn: &Connection, class: &str, error: &anyhow::Error, context: &Value) {
        let message = error.to_string();
        let chain: Vec<String> = error.chain().skip(1).map(ToString::to_string).collect();
        let backtrace = (!chain.is_empty()).then(|| chain.join("\n"));
        let context = match context {
            Value::Object(map) if !map.is_empty() => Some(context.to_string()),
            _ => None,
        };
        let result = conn.execute(
            "INSERT INTO error_logs (error_class, message, backtrace, context_json, created_at) \
             VALUES (?, ?, ?, ?, ?)",
            params![
                class,
                message,
                backtrace,
                context,
                time::format(time::now())
            ],
        );
        if let Err(e) = result {
            tracing::error!("[error_log] failed to persist: {e}");
        }
    }

    /// "Class: message", for the list.
    #[must_use]
    pub fn summary(&self) -> String {
        format!("{}: {}", self.error_class, self.message)
    }

    #[must_use]
    pub fn backtrace_lines(&self) -> Vec<&str> {
        self.backtrace
            .as_deref()
            .unwrap_or_default()
            .lines()
            .collect()
    }

    /// # Errors
    /// On database failure.
    pub fn find(conn: &Connection, id: i64) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                "SELECT id, error_class, message, backtrace, context_json, created_at \
                 FROM error_logs WHERE id = ?",
                [id],
                Self::from_row,
            )
            .optional()?)
    }

    /// Newest first.
    ///
    /// # Errors
    /// On database failure.
    pub fn page(conn: &Connection, limit: i64, offset: i64) -> Result<Vec<Self>> {
        let mut stmt = conn.prepare(
            "SELECT id, error_class, message, backtrace, context_json, created_at \
             FROM error_logs ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
        )?;
        let rows = stmt.query_map([limit, offset], Self::from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// # Errors
    /// On database failure.
    pub fn count(conn: &Connection) -> Result<i64> {
        Ok(conn.query_row("SELECT count(*) FROM error_logs", [], |row| row.get(0))?)
    }
}
