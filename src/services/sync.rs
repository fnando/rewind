//! Mirrors each enabled source's play history from the Rewind plugin's
//! changes feed into `plays`.
//!
//! The plugin owns play detection: one record per playback session with a
//! stable id, and its own call on whether the play counts (`scrobbled`). A
//! record re-appears in the feed whenever it changes, so every entry is
//! applied as an upsert keyed on that id. Each source keeps the feed's
//! sequence number as its cursor.

use std::collections::BTreeMap;
use std::fmt;
use std::time::Instant;

use anyhow::{Context, Result, bail};
use rusqlite::Connection;
use serde_json::{Value, json};

use crate::config::Config;
use crate::db;
use crate::models::play::{NewPlay, Play, Timing};
use crate::models::{ErrorLog, Source};
use crate::services::jellyfin;
use crate::services::sources::jellyfin::Adapter;
use crate::time;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Outcome {
    Written,
    Updated,
    Removed,
    Unchanged,
    Ignored,
    Skipped,
    Deferred,
}

impl fmt::Display for Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Written => "written",
            Self::Updated => "updated",
            Self::Removed => "removed",
            Self::Unchanged => "unchanged",
            Self::Ignored => "ignored",
            Self::Skipped => "skipped",
            Self::Deferred => "deferred",
        })
    }
}

/// How many entries ended in each outcome.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Tally(pub BTreeMap<Outcome, usize>);

impl Tally {
    fn add(&mut self, outcome: Outcome) {
        *self.0.entry(outcome).or_default() += 1;
    }

    #[must_use]
    pub fn get(&self, outcome: Outcome) -> usize {
        self.0.get(&outcome).copied().unwrap_or(0)
    }
}

impl fmt::Display for Tally {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            return f.write_str("no changes");
        }
        let parts: Vec<String> = self.0.iter().map(|(o, n)| format!("{n} {o}")).collect();
        f.write_str(&parts.join(", "))
    }
}

/// Syncs every enabled source. One failing source doesn't stop the rest.
pub fn run_once(config: &Config, conn: &Connection) -> Result<usize> {
    let started = Instant::now();
    let key = config.resolved_secret_key()?;
    let sources = Source::enabled(conn)?;
    for source in &sources {
        if let Err(error) = sync_source(config, conn, &key, source) {
            // Auth failures are often transient (expired token, restart), so
            // the source stays enabled and retries next run.
            if is_auth_error(&error) {
                tracing::warn!("[sync] source {} unauthorized: {error:#}", source.id);
            } else {
                tracing::error!("[sync] source {} failed: {error:#}", source.id);
            }
        }
    }
    tracing::info!(
        "[sync] run done: {} sources in {:?}",
        sources.len(),
        started.elapsed()
    );
    Ok(sources.len())
}

#[must_use]
pub fn is_auth_error(error: &anyhow::Error) -> bool {
    error.chain().any(|e| {
        matches!(
            e.downcast_ref::<jellyfin::Error>(),
            Some(jellyfin::Error::Auth(_))
        )
    })
}

/// Applies the feed for one source, page by page. A page's cursor is saved
/// once every entry on it is applied; a deferred entry holds the cursor so
/// the page is re-read (idempotently) next run.
pub fn sync_source(
    config: &Config,
    conn: &Connection,
    key: &[u8; 32],
    source: &Source,
) -> Result<Tally> {
    let result = apply_feed(config, conn, key, source);
    if let Err(error) = &result {
        ErrorLog::record(
            conn,
            "SyncError",
            error,
            &json!({"component": "sync", "source_id": source.id, "user_id": source.user_id}),
        );
        let _ = Source::record_error(conn, source.id, &format!("{error:#}"));
    }
    result
}

fn apply_feed(
    config: &Config,
    conn: &Connection,
    key: &[u8; 32],
    source: &Source,
) -> Result<Tally> {
    let started = Instant::now();
    let token = source
        .access_token(key)
        .context("can't read this account's token; reconnect it in Settings")?;
    let mut adapter = Adapter::new(config, source.clone(), token);
    refresh_user_name(conn, source, &adapter)?;

    let mut tally = Tally::default();
    // Read the stored cursor, not a possibly stale copy.
    let mut since = Source::find(conn, source.id)?.map_or(0, |s| s.since());
    loop {
        let page = adapter.changes(since)?;
        let entries = page["items"].as_array().cloned().unwrap_or_default();
        for entry in &entries {
            tally.add(record_entry(conn, source, &mut adapter, entry)?);
        }
        let deferred = tally.get(Outcome::Deferred);
        if deferred > 0 {
            let message = format!(
                "{deferred} of {} plays deferred (database locked); cursor held for retry",
                entries.len()
            );
            tracing::warn!("[sync] source {}: {message}", source.id);
            // Best effort: the same lock may well block this write too.
            if let Err(error) = Source::record_error(conn, source.id, &message) {
                tracing::warn!(
                    "[sync] source {}: couldn't record the deferral: {error:#}",
                    source.id
                );
            }
            return Ok(tally);
        }
        since = page["nextSince"].as_i64().unwrap_or(since);
        Source::save_cursor(conn, source.id, Some(since))?;
        if !page["hasMore"].as_bool().unwrap_or(false) || entries.is_empty() {
            break;
        }
    }
    tracing::info!(
        "[sync] source {}: {tally} in {:?}",
        source.id,
        started.elapsed()
    );
    Ok(tally)
}

/// Keeps the account's username current (it can be renamed). Best effort.
fn refresh_user_name(conn: &Connection, source: &Source, adapter: &Adapter) -> Result<()> {
    if let Some(name) = adapter.client().current_user_name()
        && source.external_user_name.as_deref() != Some(name.as_str())
    {
        Source::set_user_name(conn, source.id, &name)?;
    }
    Ok(())
}

/// The plays-table key for a plugin record.
#[must_use]
pub fn event_id(entry: &Value) -> String {
    format!("rewind:{}", entry["id"].as_str().unwrap_or_default())
}

#[allow(clippy::cast_possible_truncation)]
fn timing(entry: &Value) -> Timing {
    Timing {
        ended_at: entry["endedAt"].as_str().and_then(time::parse),
        played_seconds: entry["playedTicks"].as_i64().map(|t| t / 10_000_000),
        progress: entry["progress"].as_f64(),
    }
}

fn text(entry: &Value, key: &str) -> Option<String> {
    entry[key]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// Applies one feed entry as its own committed write:
///
/// - deleted, or not (or no longer) a scrobble: remove its play, if any.
/// - a scrobble already recorded: update how far it got.
/// - a new scrobble: resolve the item and record it, or skip it when the
///   item can't be matched.
///
/// A locked database defers the entry; other errors propagate and hold the
/// cursor.
pub fn record_entry(
    conn: &Connection,
    source: &Source,
    adapter: &mut Adapter,
    entry: &Value,
) -> Result<Outcome> {
    match apply_entry(conn, source, adapter, entry) {
        Err(error) if db::is_locked(&error) => {
            tracing::warn!(
                "[sync] source {}: deferred {} — database locked",
                source.id,
                event_id(entry)
            );
            Ok(Outcome::Deferred)
        }
        other => other,
    }
}

fn apply_entry(
    conn: &Connection,
    source: &Source,
    adapter: &mut Adapter,
    entry: &Value,
) -> Result<Outcome> {
    let key = event_id(entry);
    let existing = Play::find_by_event(conn, source.user_id, &source.instance_id, &key)?;
    let counts =
        entry["scrobbled"].as_bool() == Some(true) && entry["deleted"].as_bool() != Some(true);

    if !counts {
        return Ok(match existing {
            Some(play) => {
                Play::delete(conn, play.id)?;
                Outcome::Removed
            }
            None => Outcome::Ignored,
        });
    }
    if let Some(play) = existing {
        return Ok(if play.update_timing(conn, &timing(entry))? {
            Outcome::Updated
        } else {
            Outcome::Unchanged
        });
    }
    let Some(started_at) = entry["startedAt"].as_str().and_then(time::parse) else {
        bail!("play {key} has no start time");
    };
    let Some(item) = adapter.resolve_entry(conn, entry)? else {
        skipped(conn, source, entry);
        return Ok(Outcome::Skipped);
    };
    let created = Play::create(
        conn,
        &NewPlay {
            user_id: source.user_id,
            item_id: item.id,
            source: source.kind.clone(),
            source_id: Some(source.id),
            instance_id: Some(source.instance_id.clone()),
            source_event_id: Some(key),
            started_at: Some(started_at),
            timing: timing(entry),
            client: text(entry, "client"),
            device_name: text(entry, "deviceName"),
            play_method: text(entry, "playMethod"),
        },
    );
    match created {
        Ok(_) => Ok(Outcome::Written),
        Err(error)
            if error
                .downcast_ref::<rusqlite::Error>()
                .is_some_and(db::is_unique_violation) =>
        {
            Ok(Outcome::Unchanged)
        }
        Err(error) => Err(error),
    }
}

/// A scrobble whose item can't be matched is dropped (the cursor moves on),
/// so it's surfaced on the errors page.
fn skipped(conn: &Connection, source: &Source, entry: &Value) {
    let error = anyhow::anyhow!(
        "Unmatched play: {} {:?}",
        entry["itemType"].as_str().unwrap_or_default(),
        entry["name"].as_str().unwrap_or_default()
    );
    ErrorLog::record(
        conn,
        "UnmatchedPlay",
        &error,
        &json!({
            "component": "sync",
            "source_id": source.id,
            "user_id": source.user_id,
            "play_id": entry["id"],
            "item_id": entry["itemId"],
        }),
    );
}

/// Forgets what was imported from these sources: deletes their plays and
/// clears their cursors, so the next sync re-imports the full history. Also
/// takes the user's orphaned plays from the same server (a deleted
/// connection's). Returns how many plays were removed.
pub fn reset(conn: &Connection, sources: &[Source]) -> Result<usize> {
    let mut removed = 0;
    for source in sources {
        removed += conn.execute(
            "DELETE FROM plays WHERE user_id = ?1 AND source = ?2 \
             AND (source_id = ?3 OR (source_id IS NULL AND instance_id = ?4))",
            rusqlite::params![source.user_id, source.kind, source.id, source.instance_id],
        )?;
        Source::clear_cursor(conn, source.id)?;
    }
    Ok(removed)
}
