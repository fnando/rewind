//! The Jellyfin id ledger (`jellyfin_seen`) and the re-tag healer.
//!
//! Jellyfin derives an item id from the file path, so re-tagging a track in
//! Picard (which moves the file) gives the same audio a new id, stranding the
//! plays recorded under the old row. The MusicBrainz *recording* id survives a
//! re-tag, so it's used here, and only here, to recognise "this new id is the
//! same audio as a row we already have". When the new track's recording
//! matches exactly one played row whose own Jellyfin id is now gone (404),
//! that row's plays and ratings move onto the new one. Any doubt skips: a
//! false merge is never acceptable.

use std::collections::HashSet;

use anyhow::{Result, bail};
use rusqlite::{Connection, params};

use crate::models::Item;

/// A play's id, user, start and plugin key.
type PlayRow = (i64, i64, String, Option<String>, Option<String>);
/// A rating row: id, user, rating, review and its timestamps.
type RatingRow = (
    i64,
    i64,
    Option<i64>,
    Option<String>,
    Option<String>,
    Option<String>,
);
use crate::time;

fn presence(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|v| !v.is_empty())
}

/// Whether this id was already logged on this server.
pub fn seen(conn: &Connection, jellyfin_id: Option<&str>, instance_id: &str) -> Result<bool> {
    let Some(jellyfin_id) = presence(jellyfin_id) else {
        return Ok(false);
    };
    Ok(conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM jellyfin_seen WHERE instance_id = ? AND jellyfin_id = ?)",
        params![instance_id, jellyfin_id],
        |row| row.get(0),
    )?)
}

/// Records the id → item mapping (plus the recording for tracks). A later
/// sighting without a recording keeps the one captured first.
pub fn remember(
    conn: &Connection,
    item: &Item,
    jellyfin_id: Option<&str>,
    media_type: &str,
    instance_id: &str,
    recording_mbid: Option<&str>,
) -> Result<()> {
    let Some(jellyfin_id) = presence(jellyfin_id) else {
        return Ok(());
    };
    conn.execute(
        "INSERT INTO jellyfin_seen (instance_id, jellyfin_id, item_id, media_type, recording_mbid, seen_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
         ON CONFLICT (instance_id, jellyfin_id) DO UPDATE SET \
           item_id = excluded.item_id, media_type = excluded.media_type, \
           recording_mbid = coalesce(excluded.recording_mbid, recording_mbid), \
           seen_at = excluded.seen_at",
        params![
            instance_id,
            jellyfin_id,
            item.id,
            media_type,
            presence(recording_mbid),
            time::format(time::now())
        ],
    )?;
    Ok(())
}

/// Heals a re-tag onto `target`. `present` answers whether a Jellyfin id
/// still exists (`None` when it can't tell). Returns the absorbed item's id.
/// Never fails: a hiccup just retries on the next sighting.
pub fn reconcile(
    conn: &Connection,
    target: &Item,
    recording_mbid: Option<&str>,
    instance_id: &str,
    present: &dyn Fn(&str) -> Option<bool>,
) -> Option<i64> {
    let recording = presence(recording_mbid)?;
    match try_reconcile(conn, target, recording, instance_id, present) {
        Ok(absorbed) => absorbed,
        Err(error) => {
            tracing::warn!("[archive] reconcile failed: {error:#}");
            None
        }
    }
}

fn try_reconcile(
    conn: &Connection,
    target: &Item,
    recording: &str,
    instance_id: &str,
    present: &dyn Fn(&str) -> Option<bool>,
) -> Result<Option<i64>> {
    let candidates = Item::list(
        conn,
        "WHERE media_type = 'track' AND id != ?1 AND id IN ( \
           SELECT item_id FROM jellyfin_seen \
           WHERE recording_mbid = ?2 AND instance_id = ?3 AND media_type = 'track')",
        params![target.id, recording, instance_id],
    )?;
    let mut dead = Vec::new();
    for item in candidates {
        if !worth_keeping(conn, &item)? {
            continue;
        }
        let gone = item
            .jellyfin_id
            .as_deref()
            .is_some_and(|id| present(id) == Some(false));
        if gone {
            dead.push(item);
        }
    }
    match dead.as_slice() {
        [one] => {
            absorb(conn, one, target)?;
            Ok(Some(one.id))
        }
        [] => Ok(None),
        many => {
            tracing::info!(
                "[archive] ambiguous re-tag for item {}: {} dead twins — skipped",
                target.id,
                many.len()
            );
            Ok(None)
        }
    }
}

fn worth_keeping(conn: &Connection, item: &Item) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM plays WHERE item_id = ?1) \
             OR EXISTS (SELECT 1 FROM user_items WHERE item_key = ?2)",
        params![item.id, item.rating_key()],
        |row| row.get(0),
    )?)
}

/// Moves `source`'s plays and ratings onto `target`, then deletes `source`.
/// A play the target already has (same start, or same plugin record) is
/// dropped instead of duplicated.
fn absorb(conn: &Connection, source: &Item, target: &Item) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    migrate_user_items(&tx, &source.rating_key(), &target.rating_key())?;

    let mut by_time = HashSet::new();
    let mut by_event = HashSet::new();
    {
        let mut stmt = tx.prepare(
            "SELECT user_id, started_at, instance_id, source_event_id FROM plays WHERE item_id = ?",
        )?;
        let rows = stmt.query_map([target.id], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })?;
        for row in rows {
            let (user, started, instance, event) = row?;
            by_time.insert((user, started));
            if let (Some(i), Some(e)) = (instance, event) {
                by_event.insert((user, i, e));
            }
        }
    }
    let plays: Vec<PlayRow> = {
        let mut stmt = tx.prepare(
            "SELECT id, user_id, started_at, instance_id, source_event_id FROM plays WHERE item_id = ?",
        )?;
        let rows = stmt.query_map([source.id], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        })?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    for (id, user, started, instance, event) in plays {
        let time_key = (user, started);
        let event_key = instance.zip(event).map(|(i, e)| (user, i, e));
        let duplicate =
            by_time.contains(&time_key) || event_key.as_ref().is_some_and(|k| by_event.contains(k));
        if duplicate {
            tx.execute("DELETE FROM plays WHERE id = ?", [id])?;
        } else {
            tx.execute("UPDATE plays SET item_id = ? WHERE id = ?", [target.id, id])?;
            by_time.insert(time_key);
            if let Some(key) = event_key {
                by_event.insert(key);
            }
        }
    }
    tx.execute(
        "UPDATE jellyfin_seen SET item_id = ? WHERE item_id = ?",
        [target.id, source.id],
    )?;
    let remaining: i64 = tx.query_row(
        "SELECT count(*) FROM plays WHERE item_id = ?",
        [source.id],
        |r| r.get(0),
    )?;
    if remaining > 0 {
        bail!(
            "refusing to delete item {} ({:?}) — it still has plays",
            source.id,
            source.title
        );
    }
    tx.execute("DELETE FROM items WHERE id = ?", [source.id])?;
    tx.commit()?;
    tracing::info!(
        "[archive] re-tag healed: item {} ({:?}) absorbed into {}",
        source.id,
        source.title,
        target.id
    );
    Ok(())
}

fn migrate_user_items(conn: &Connection, old_key: &str, new_key: &str) -> Result<()> {
    if old_key == new_key {
        return Ok(());
    }
    let rows: Vec<RatingRow> = {
        let mut stmt = conn.prepare(
            "SELECT id, user_id, rating, review, review_created_at, review_updated_at \
             FROM user_items WHERE item_key = ?",
        )?;
        let rows = stmt.query_map([old_key], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        })?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    for (id, user_id, rating, review, created, updated) in rows {
        let target: Option<(i64, Option<i64>, Option<String>)> = conn
            .query_row(
                "SELECT id, rating, review FROM user_items WHERE user_id = ? AND item_key = ?",
                params![user_id, new_key],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .ok();
        match target {
            None => {
                conn.execute(
                    "UPDATE user_items SET item_key = ? WHERE id = ?",
                    params![new_key, id],
                )?;
            }
            Some((target_id, target_rating, target_review)) => {
                if target_rating.is_none() && rating.is_some() {
                    conn.execute(
                        "UPDATE user_items SET rating = ? WHERE id = ?",
                        params![rating, target_id],
                    )?;
                }
                let blank = |v: &Option<String>| v.as_deref().is_none_or(|s| s.trim().is_empty());
                if blank(&target_review) && !blank(&review) {
                    conn.execute(
                        "UPDATE user_items SET review = ?, review_created_at = ?, review_updated_at = ? \
                         WHERE id = ?",
                        params![review, created, updated, target_id],
                    )?;
                }
                conn.execute("DELETE FROM user_items WHERE id = ?", [id])?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use crate::models::item::Attrs;
    use crate::models::play::{NewPlay, Play};
    use crate::models::{User, UserItem};

    struct Fixture {
        conn: Connection,
        user: i64,
    }

    fn fixture() -> Fixture {
        let conn = db::open_in_memory().unwrap();
        let user = User::create(&conn, "fnando", None, "x").unwrap().id;
        Fixture { conn, user }
    }

    fn track(f: &Fixture, key: &str, jellyfin_id: &str) -> Item {
        let item = Item::upsert(
            &f.conn,
            "track",
            key,
            &Attrs::new()
                .text("title", Some("Song"))
                .text("jellyfin_id", Some(jellyfin_id)),
        )
        .unwrap();
        remember(
            &f.conn,
            &item,
            Some(jellyfin_id),
            "track",
            "srv",
            Some("rec-1"),
        )
        .unwrap();
        item
    }

    fn play(f: &Fixture, item: &Item, at: &str) {
        Play::create(
            &f.conn,
            &NewPlay {
                user_id: f.user,
                item_id: item.id,
                source: "jellyfin".into(),
                started_at: Some(at.parse().unwrap()),
                ..NewPlay::default()
            },
        )
        .unwrap();
    }

    fn plays_on(f: &Fixture, item: &Item) -> i64 {
        f.conn
            .query_row(
                "SELECT count(*) FROM plays WHERE item_id = ?",
                [item.id],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[test]
    fn remember_keeps_the_first_recording() {
        let f = fixture();
        let item = track(&f, "mbid:rt:a", "jf-a");
        remember(&f.conn, &item, Some("jf-a"), "track", "srv", None).unwrap();
        let recording: Option<String> = f
            .conn
            .query_row("SELECT recording_mbid FROM jellyfin_seen", [], |r| r.get(0))
            .unwrap();
        assert_eq!(recording.as_deref(), Some("rec-1"));
        assert!(seen(&f.conn, Some("jf-a"), "srv").unwrap());
        assert!(!seen(&f.conn, Some("jf-a"), "other").unwrap());
    }

    #[test]
    fn moves_a_stranded_play_and_rating_when_the_old_id_is_gone() {
        let f = fixture();
        let old = track(&f, "mbid:rt:old", "jf-old");
        play(&f, &old, "2026-11-01T10:00:00Z");
        UserItem::set_rating(&f.conn, f.user, &old.rating_key(), Some(5)).unwrap();
        let new = track(&f, "mbid:rt:new", "jf-new");

        let absorbed = reconcile(&f.conn, &new, Some("rec-1"), "srv", &|id| {
            Some(id != "jf-old")
        });
        assert_eq!(absorbed, Some(old.id));
        assert_eq!(plays_on(&f, &new), 1);
        assert!(Item::find(&f.conn, old.id).unwrap().is_none());
        let rating = UserItem::find(&f.conn, f.user, &new.rating_key())
            .unwrap()
            .unwrap();
        assert_eq!(rating.rating, Some(5));
    }

    #[test]
    fn leaves_rows_alone_when_alive_unknown_or_ambiguous() {
        let f = fixture();
        let old = track(&f, "mbid:rt:old", "jf-old");
        play(&f, &old, "2026-11-01T10:00:00Z");
        let new = track(&f, "mbid:rt:new", "jf-new");

        assert_eq!(
            reconcile(&f.conn, &new, Some("rec-1"), "srv", &|_| Some(true)),
            None
        );
        assert_eq!(
            reconcile(&f.conn, &new, Some("rec-1"), "srv", &|_| None),
            None
        );

        let twin = track(&f, "mbid:rt:twin", "jf-twin");
        play(&f, &twin, "2026-11-02T10:00:00Z");
        assert_eq!(
            reconcile(&f.conn, &new, Some("rec-1"), "srv", &|id| Some(
                id == "jf-new"
            )),
            None
        );
        assert_eq!(plays_on(&f, &old), 1);
        assert_eq!(
            reconcile(&f.conn, &new, None, "srv", &|_| Some(false)),
            None
        );
    }

    #[test]
    fn ignores_an_unplayed_unrated_twin() {
        let f = fixture();
        let old = track(&f, "mbid:rt:old", "jf-old");
        let new = track(&f, "mbid:rt:new", "jf-new");
        assert_eq!(
            reconcile(&f.conn, &new, Some("rec-1"), "srv", &|_| Some(false)),
            None
        );
        assert!(Item::find(&f.conn, old.id).unwrap().is_some());
    }
}
