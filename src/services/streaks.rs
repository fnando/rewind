//! Play streaks: runs of consecutive local days with at least one play.
//!
//! Each play stores the local date it happened on (frozen at write), so the
//! runs are computed straight from `plays` with a gaps-and-islands query —
//! no derived table to keep in step, and a time zone change never moves a
//! past day.

use std::collections::BTreeMap;

use anyhow::Result;
use jiff::ToSpan;
use jiff::civil::Date;
use rusqlite::Connection;

/// Display groups, matching how stats bucket media. Types that never play
/// directly (series, album, artist) have no group.
pub const MEDIA_GROUPS: &[(&str, &str)] = &[
    ("movie", "movie"),
    ("episode", "series"),
    ("track", "music"),
    ("music_video", "music"),
];

/// Group order on the card.
pub const GROUPS: &[&str] = &["movie", "series", "music"];

/// Width of the activity strip shown on the card.
pub const STRIP_DAYS: i32 = 14;

#[must_use]
pub fn group_for(media_type: &str) -> Option<&'static str> {
    MEDIA_GROUPS
        .iter()
        .find(|(t, _)| *t == media_type)
        .map(|(_, g)| *g)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Island {
    pub length: i64,
    pub start: String,
    pub end: String,
}

impl Island {
    fn covers(&self, day: &str) -> bool {
        self.start.as_str() <= day && day <= self.end.as_str()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StripDay {
    pub date: Date,
    pub watched: bool,
    pub in_streak: bool,
    pub today: bool,
}

/// Everything a streak card needs for one scope (overall or a group).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    pub current: i64,
    pub longest: Option<Island>,
    pub is_record: bool,
    pub current_range: Option<Island>,
    pub previous_best: Option<Island>,
    pub last_streak: Option<Island>,
    pub strip: Vec<StripDay>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Streaks {
    pub overall: Summary,
    pub by_media_group: BTreeMap<&'static str, Summary>,
}

impl Streaks {
    #[must_use]
    pub fn group(&self, name: &str) -> Option<&Summary> {
        self.by_media_group.get(name)
    }
}

const GROUP_CASE: &str = "CASE items.media_type \
     WHEN 'movie' THEN 'movie' WHEN 'episode' THEN 'series' \
     WHEN 'track' THEN 'music' WHEN 'music_video' THEN 'music' END";

/// The user's streaks as of `today` (their local today).
pub fn get(conn: &Connection, user_id: i64, today: Date) -> Result<Streaks> {
    let overall = islands(
        conn,
        &format!(
            "WITH days AS ( \
               SELECT DISTINCT plays.local_date AS d, 'all' AS g FROM plays \
               JOIN items ON items.id = plays.item_id \
               WHERE plays.user_id = ?1 AND {GROUP_CASE} IS NOT NULL)"
        ),
        user_id,
    )?;
    let grouped = islands(
        conn,
        &format!(
            "WITH days AS ( \
               SELECT DISTINCT plays.local_date AS d, {GROUP_CASE} AS g FROM plays \
               JOIN items ON items.id = plays.item_id \
               WHERE plays.user_id = ?1 AND {GROUP_CASE} IS NOT NULL)"
        ),
        user_id,
    )?;
    let mut by_media_group = BTreeMap::new();
    for group in GROUPS {
        let runs = grouped.get(*group).cloned().unwrap_or_default();
        by_media_group.insert(*group, summarize(&runs, today));
    }
    let overall = summarize(&overall.get("all").cloned().unwrap_or_default(), today);
    Ok(Streaks {
        overall,
        by_media_group,
    })
}

/// Runs of consecutive days per group, from a `days(d, g)` CTE.
fn islands(
    conn: &Connection,
    days_cte: &str,
    user_id: i64,
) -> Result<BTreeMap<String, Vec<Island>>> {
    let sql = format!(
        "{days_cte}, grp AS ( \
           SELECT g, d, julianday(d) - row_number() OVER (PARTITION BY g ORDER BY d) AS anchor \
           FROM days) \
         SELECT g, min(d), max(d), count(*) FROM grp GROUP BY g, anchor"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([user_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            Island {
                start: row.get(1)?,
                end: row.get(2)?,
                length: row.get(3)?,
            },
        ))
    })?;
    let mut out: BTreeMap<String, Vec<Island>> = BTreeMap::new();
    for row in rows {
        let (group, island) = row?;
        out.entry(group).or_default().push(island);
    }
    Ok(out)
}

/// The current and longest runs, whether the current one is a record, the
/// previous best and most recent runs, and a strip of the last days.
fn summarize(islands: &[Island], today: Date) -> Summary {
    let today_s = today.to_string();
    let yesterday = today
        .checked_sub(1.day())
        .map(|d| d.to_string())
        .unwrap_or_default();
    let current_island = islands
        .iter()
        .find(|i| i.end == today_s || i.end == yesterday);
    let last_island = islands.iter().max_by(|a, b| a.end.cmp(&b.end));
    let by_length = |a: &&Island, b: &&Island| (a.length, &a.end).cmp(&(b.length, &b.end));
    let best_other = islands
        .iter()
        .filter(|i| Some(*i) != current_island)
        .max_by(by_length);
    let longest = islands.iter().max_by(by_length);

    let current = current_island.map_or(0, |i| i.length);
    let is_record = current > 0 && current >= best_other.map_or(0, |i| i.length);
    let highlight = current_island.or(last_island);

    let strip = (0..STRIP_DAYS)
        .filter_map(|offset| {
            let date = today.checked_sub((STRIP_DAYS - 1 - offset).days()).ok()?;
            let day = date.to_string();
            Some(StripDay {
                date,
                watched: islands.iter().any(|i| i.covers(&day)),
                in_streak: highlight.is_some_and(|i| i.covers(&day)),
                today: date == today,
            })
        })
        .collect();

    Summary {
        current,
        longest: longest.cloned(),
        is_record,
        current_range: current_island.cloned(),
        previous_best: best_other.cloned(),
        last_streak: last_island.cloned(),
        strip,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use crate::models::User;
    use crate::models::item::{Attrs, Item};
    use crate::models::play::{NewPlay, Play};
    use jiff::civil::date;

    struct Fixture {
        conn: Connection,
        user: i64,
        n: std::cell::Cell<i64>,
    }

    fn fixture() -> Fixture {
        let conn = db::open_in_memory().unwrap();
        let user = User::create(&conn, "fnando", None, "x").unwrap().id;
        Fixture {
            conn,
            user,
            n: std::cell::Cell::new(0),
        }
    }

    impl Fixture {
        fn play(&self, day: &str, media_type: &str) {
            self.play_at(&format!("{day}T12:00:00Z"), media_type);
        }

        fn play_at(&self, at: &str, media_type: &str) {
            self.n.set(self.n.get() + 1);
            let item = Item::upsert(
                &self.conn,
                media_type,
                &format!("x:{}", self.n.get()),
                &Attrs::new().text("title", Some("t")),
            )
            .unwrap();
            Play::create(
                &self.conn,
                &NewPlay {
                    user_id: self.user,
                    item_id: item.id,
                    source: "manual".into(),
                    started_at: Some(at.parse().unwrap()),
                    ..NewPlay::default()
                },
            )
            .unwrap();
        }

        fn streaks(&self) -> Streaks {
            get(&self.conn, self.user, date(2026, 10, 18)).unwrap()
        }
    }

    #[test]
    fn no_plays_is_a_zero_streak() {
        let s = fixture().streaks();
        assert_eq!(s.overall.current, 0);
        assert_eq!(s.overall.longest, None);
        assert_eq!(
            s.by_media_group.keys().copied().collect::<Vec<_>>(),
            ["movie", "music", "series"]
        );
        assert_eq!(s.group("movie").unwrap().current, 0);
    }

    #[test]
    fn a_play_today_or_yesterday_keeps_the_streak_alive() {
        let f = fixture();
        f.play("2026-10-18", "movie");
        let s = f.streaks();
        assert_eq!(s.overall.current, 1);
        assert!(s.overall.is_record);
        assert_eq!(s.group("movie").unwrap().current, 1);

        let f = fixture();
        f.play("2026-10-17", "movie");
        assert_eq!(f.streaks().overall.current, 1);

        let f = fixture();
        f.play("2026-10-16", "movie");
        let s = f.streaks();
        assert_eq!(s.overall.current, 0);
        assert_eq!(s.overall.longest.unwrap().length, 1);
    }

    #[test]
    fn several_plays_on_a_day_count_once() {
        let f = fixture();
        f.play("2026-10-18", "movie");
        f.play("2026-10-18", "movie");
        assert_eq!(f.streaks().overall.longest.unwrap().length, 1);
    }

    #[test]
    fn a_gap_splits_runs_and_the_longest_wins() {
        let f = fixture();
        for d in ["2026-10-10", "2026-10-11", "2026-10-12", "2026-10-18"] {
            f.play(d, "movie");
        }
        let s = f.streaks();
        assert_eq!(s.overall.current, 1);
        let longest = s.overall.longest.unwrap();
        assert_eq!(
            (longest.length, longest.start.as_str(), longest.end.as_str()),
            (3, "2026-10-10", "2026-10-12")
        );
        assert!(!s.overall.is_record);
    }

    #[test]
    fn groups_have_their_own_runs() {
        let f = fixture();
        f.play("2026-10-16", "movie");
        f.play("2026-10-17", "episode");
        f.play("2026-10-18", "movie");
        f.play("2026-10-17", "track");
        f.play("2026-10-18", "music_video");
        f.play("2026-10-18", "album");
        let s = f.streaks();
        assert_eq!(s.overall.current, 3);
        assert_eq!(s.group("movie").unwrap().current, 1);
        assert_eq!(s.group("series").unwrap().current, 1);
        assert_eq!(s.group("music").unwrap().current, 2);
    }

    #[test]
    fn an_active_streak_exposes_its_range_and_strip() {
        let f = fixture();
        f.play("2026-10-17", "movie");
        f.play("2026-10-18", "movie");
        let s = f.streaks().overall;
        let range = s.current_range.unwrap();
        assert_eq!(
            (range.start.as_str(), range.end.as_str()),
            ("2026-10-17", "2026-10-18")
        );
        assert_eq!(s.strip.len(), 14);
        assert!(s.strip[13].today && s.strip[13].in_streak && s.strip[12].in_streak);
        assert!(!s.strip[0].watched);
    }

    #[test]
    fn a_record_streak_exposes_the_previous_best() {
        let f = fixture();
        for d in [
            "2026-09-01",
            "2026-09-02",
            "2026-09-03",
            "2026-10-14",
            "2026-10-15",
            "2026-10-16",
            "2026-10-17",
            "2026-10-18",
        ] {
            f.play(d, "movie");
        }
        let s = f.streaks().overall;
        assert!(s.is_record);
        assert_eq!(s.current, 5);
        let best = s.previous_best.unwrap();
        assert_eq!((best.length, best.start.as_str()), (3, "2026-09-01"));
    }

    #[test]
    fn an_ended_streak_highlights_the_last_run() {
        let f = fixture();
        for d in ["2026-10-08", "2026-10-09", "2026-10-10"] {
            f.play(d, "movie");
        }
        let s = f.streaks().overall;
        assert_eq!(s.current, 0);
        assert_eq!(s.current_range, None);
        let last = s.last_streak.unwrap();
        assert_eq!((last.length, last.end.as_str()), (3, "2026-10-10"));
        assert_eq!(s.strip.iter().filter(|d| d.in_streak).count(), 3);
    }

    #[test]
    fn a_late_night_play_counts_on_the_local_day_even_after_a_zone_change() {
        let f = fixture();
        User::set_timezone(&f.conn, f.user, "America/Vancouver").unwrap();
        // 06:30 UTC on the 18th is 23:30 on the 17th in Vancouver.
        f.play_at("2026-10-18T06:30:00Z", "movie");
        User::set_timezone(&f.conn, f.user, "UTC").unwrap();
        let s = f.streaks();
        assert_eq!(s.overall.current_range.unwrap().end, "2026-10-17");
    }
}
