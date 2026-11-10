//! The numbers behind the stats page: totals, the hero sentence, the rhythm
//! chart, the activity heatmap and the top lists. Days and months come from
//! each play's frozen local date, so every chart agrees with History.

use std::collections::{BTreeMap, HashMap, HashSet};

use anyhow::Result;
use jiff::civil::Date;
use jiff::{Timestamp, ToSpan};
use rusqlite::Connection;
use rusqlite::types::Value as SqlValue;
use serde_json::Value;

use crate::models::play::MUSIC_MEDIA_TYPES;
use crate::models::{Item, Play};
use crate::time;

const MONTH_NAMES: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
const DIRECTOR_JOBS: &[&str] = &["Director", "Writer", "Screenplay", "Creator"];

/// The window the page covers.
#[derive(Debug, Clone)]
pub struct Period {
    pub kind: String,
    pub from: Option<Timestamp>,
    pub to: Option<Timestamp>,
    /// The same window as local dates, for filtering by day.
    pub from_date: Option<Date>,
    pub to_date: Option<Date>,
    pub label: String,
    pub today: Date,
}

/// Week = the last 7 local days, month = the last 30, year = since Jan 1,
/// all = everything; "custom" reads `from`/`to` dates (YYYY-MM-DD).
#[must_use]
pub fn resolve_period(kind: &str, from: Option<&str>, to: Option<&str>, zone: &str) -> Period {
    let today = time::today(zone);
    let start_of = |date: Date| time::local_to_utc(&format!("{date}T00:00"), zone);
    let (kind, from_date, to_date) = match kind {
        "week" => ("week", today.checked_sub(6.days()).ok(), Some(today)),
        "month" => ("month", today.checked_sub(29.days()).ok(), Some(today)),
        "all" => ("all", None, None),
        "custom" => {
            let parse = |v: Option<&str>| {
                v.and_then(|s| s.get(..10))
                    .and_then(|s| s.parse::<Date>().ok())
            };
            (
                "custom",
                Some(parse(from).unwrap_or_else(|| today.checked_sub(365.days()).unwrap_or(today))),
                Some(parse(to).unwrap_or(today)),
            )
        }
        _ => ("year", Date::new(today.year(), 1, 1).ok(), Some(today)),
    };
    let label = match kind {
        "week" => "Last 7 days".to_string(),
        "month" => "Last 30 days".to_string(),
        "all" => "All time".to_string(),
        "custom" => "Custom".to_string(),
        _ => today.year().to_string(),
    };
    Period {
        kind: kind.into(),
        from: from_date.and_then(start_of),
        to: to_date.and_then(|d| d.tomorrow().ok()).and_then(start_of),
        from_date,
        to_date,
        label,
        today,
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Totals {
    pub plays: usize,
    pub unique_titles: usize,
    pub movies_count: usize,
    pub episodes_count: usize,
    pub tracks_count: usize,
    pub movies_hours: f64,
    pub episodes_hours: f64,
    pub hours_watched: f64,
    pub listening_hours: f64,
    pub rewatches: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Headline {
    pub big_number: usize,
    pub hours_sentence: String,
    pub unit: &'static str,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Busiest {
    pub label: String,
    pub hours: i64,
    pub context: &'static str,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Cards {
    pub different_titles: usize,
    pub rewatches: usize,
    pub rewatch_label: String,
    pub busiest: Option<Busiest>,
    pub average_per_week: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RhythmRow {
    pub label: String,
    pub movies: f64,
    pub episodes: f64,
    pub tracks: f64,
    pub total: f64,
    pub tooltip: String,
    pub peak: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeatCell {
    pub date: Date,
    pub count: usize,
    pub level: u8,
    pub in_filter: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Heatmap {
    pub cells: Vec<HeatCell>,
    pub days_with_plays: usize,
    pub biggest_day: Option<(Date, usize)>,
}

#[derive(Debug, Clone)]
pub struct Genre {
    pub name: String,
    pub count: usize,
    pub sample: Option<Item>,
}

#[derive(Debug, Clone)]
pub struct Show {
    pub parent_external_id: String,
    pub name: String,
    pub episode_count: usize,
    pub item: Option<Item>,
}

#[derive(Debug, Clone)]
pub struct Ranked {
    pub name: String,
    pub count: usize,
    pub item: Option<Item>,
    /// For tracks: the album, whose cover the row shows.
    pub album: Option<Item>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Person {
    pub name: String,
    pub count: usize,
    pub profile_path: Option<String>,
    pub top_item_title: Option<String>,
}

pub struct Stats {
    pub period: Period,
    pub totals: Totals,
    pub headline: Headline,
    pub cards: Cards,
    pub rhythm: Vec<RhythmRow>,
    pub heatmap: Heatmap,
    pub top_genres: Vec<Genre>,
    pub top_shows: Vec<Show>,
    pub top_movies: Vec<Ranked>,
    pub top_cast: Vec<Person>,
    pub top_directors: Vec<Person>,
    pub top_artists: Vec<Ranked>,
    pub top_albums: Vec<Ranked>,
    pub top_tracks: Vec<Ranked>,
}

/// The `items.media_type` values a filter covers (`None` = everything).
fn media_filter(media_type: &str) -> Option<Vec<&'static str>> {
    match media_type {
        "movie" => Some(vec!["movie"]),
        "series" => Some(vec!["episode"]),
        "music" => Some(MUSIC_MEDIA_TYPES.to_vec()),
        _ => None,
    }
}

fn load_plays(
    conn: &Connection,
    user_id: i64,
    media_type: &str,
    from: Option<Timestamp>,
    to: Option<Timestamp>,
) -> Result<Vec<(Play, Item)>> {
    let mut sql = format!(
        "SELECT {}, {} FROM plays JOIN items ON items.id = plays.item_id WHERE plays.user_id = ?",
        crate::models::play::COLUMNS,
        crate::models::item::COLUMNS
    );
    let mut params = vec![SqlValue::Integer(user_id)];
    if let Some(from) = from {
        sql.push_str(" AND plays.started_at >= ?");
        params.push(SqlValue::Text(time::format(from)));
    }
    if let Some(to) = to {
        sql.push_str(" AND plays.started_at < ?");
        params.push(SqlValue::Text(time::format(to)));
    }
    if let Some(types) = media_filter(media_type) {
        sql.push_str(" AND items.media_type IN (");
        sql.push_str(&vec!["?"; types.len()].join(", "));
        sql.push(')');
        params.extend(types.into_iter().map(|t| SqlValue::Text(t.into())));
    }
    sql.push_str(" ORDER BY plays.started_at, plays.id");
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(params), |row| {
        Ok((Play::from_row(row)?, Item::from_row_at(row, 20)?))
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

#[allow(clippy::cast_precision_loss)]
fn hours(item: &Item) -> f64 {
    item.runtime.unwrap_or(0) as f64 / 60.0
}

fn is_music(item: &Item) -> bool {
    MUSIC_MEDIA_TYPES.contains(&item.media_type.as_str())
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

fn pluralize_hours(count: i64) -> String {
    format!("{count} {}", if count == 1 { "hour" } else { "hours" })
}

#[allow(clippy::cast_possible_truncation)]
fn rounded(value: f64) -> i64 {
    value.round() as i64
}

pub fn compute(
    conn: &Connection,
    user_id: i64,
    zone: &str,
    media_type: &str,
    period: Period,
) -> Result<Stats> {
    let plays = load_plays(conn, user_id, media_type, period.from, period.to)?;
    let totals = totals(&plays);
    let rhythm = rhythm(&plays, &period);
    let headline = Headline {
        big_number: plays.len(),
        hours_sentence: hero_sentence(totals.hours_watched, totals.listening_hours),
        unit: headline_unit(media_type, plays.len()),
    };
    let cards = cards(&plays, &totals, &rhythm, &period, media_type);
    let heatmap = heatmap(conn, user_id, zone, media_type, &period)?;
    let mut shows_cache = HashMap::new();
    Ok(Stats {
        top_genres: top_genres(conn, &plays, &mut shows_cache)?,
        top_shows: top_shows(conn, &plays, &mut shows_cache)?,
        top_movies: top_movies(&plays),
        top_cast: top_people(&plays, |item| {
            item.credits()
                .and_then(|c| c.get("cast"))
                .and_then(Value::as_array)
                .map(|cast| cast.iter().take(10).cloned().collect())
                .unwrap_or_default()
        }),
        top_directors: top_people(&plays, |item| {
            item.credits()
                .and_then(|c| c.get("crew"))
                .and_then(Value::as_array)
                .map(|crew| {
                    crew.iter()
                        .filter(|c| {
                            c["job"]
                                .as_str()
                                .is_some_and(|j| DIRECTOR_JOBS.contains(&j))
                        })
                        .cloned()
                        .collect()
                })
                .unwrap_or_default()
        }),
        top_artists: rank_music(conn, &plays, "artist_external_id")?,
        top_albums: rank_music(conn, &plays, "album_external_id")?,
        top_tracks: top_tracks(conn, &plays)?,
        period,
        totals,
        headline,
        cards,
        rhythm,
        heatmap,
    })
}

fn totals(plays: &[(Play, Item)]) -> Totals {
    let movies: Vec<&Item> = plays
        .iter()
        .map(|(_, i)| i)
        .filter(|i| i.media_type == "movie")
        .collect();
    let episodes: Vec<&Item> = plays
        .iter()
        .map(|(_, i)| i)
        .filter(|i| i.media_type == "episode")
        .collect();
    // Music videos count as listening, never as movies.
    let tracks: Vec<&Item> = plays
        .iter()
        .map(|(_, i)| i)
        .filter(|i| is_music(i))
        .collect();
    let unique = |items: &[&Item], key: fn(&Item) -> Option<String>| {
        items
            .iter()
            .filter_map(|i| key(i))
            .collect::<HashSet<_>>()
            .len()
    };
    let unique_titles = unique(&movies, |i| Some(i.external_id.clone()))
        + unique(&episodes, |i| {
            i.parent_external_id.clone().or(Some(String::new()))
        })
        + unique(&tracks, |i| Some(i.external_id.clone()));
    let movies_hours: f64 = movies.iter().map(|i| hours(i)).sum();
    let episodes_hours: f64 = episodes.iter().map(|i| hours(i)).sum();
    let listening_hours: f64 = tracks.iter().map(|i| hours(i)).sum();
    let mut per_item: HashMap<i64, usize> = HashMap::new();
    for (play, _) in plays {
        *per_item.entry(play.item_id).or_default() += 1;
    }
    Totals {
        plays: plays.len(),
        unique_titles,
        movies_count: movies.len(),
        episodes_count: episodes.len(),
        tracks_count: tracks.len(),
        movies_hours: round1(movies_hours),
        episodes_hours: round1(episodes_hours),
        hours_watched: round1(movies_hours + episodes_hours),
        listening_hours: round1(listening_hours),
        rewatches: per_item.values().map(|c| c.saturating_sub(1)).sum(),
    }
}

/// The hero sentence about time spent.
fn hero_sentence(video: f64, audio: f64) -> String {
    let (video, audio) = (rounded(video), rounded(audio));
    if video > 0 && audio > 0 {
        return format!(
            "{} in front of the screen and {} of music.",
            pluralize_hours(video),
            pluralize_hours(audio)
        );
    }
    if audio > 0 {
        return format!("{} of music, in your ears.", pluralize_hours(audio));
    }
    if video == 0 {
        return "No time logged yet.".into();
    }
    let phrase = format!("{} in front of the screen", pluralize_hours(video));
    let (days, left) = (video / 24, video % 24);
    if days == 0 {
        return format!("{phrase}, start to finish.");
    }
    let mut parts = vec![format!("{days} day{}", if days == 1 { "" } else { "s" })];
    if left > 0 {
        parts.push(format!("{left} hour{}", if left == 1 { "" } else { "s" }));
    }
    format!(
        "{phrase}. That's {} of stories, start to finish.",
        parts.join(" and ")
    )
}

fn headline_unit(media_type: &str, count: usize) -> &'static str {
    match (media_type, count == 1) {
        ("music", true) => "listen",
        ("music", false) => "listens",
        ("movie" | "series", true) => "thing watched",
        ("movie" | "series", false) => "things watched",
        (_, true) => "thing played",
        (_, false) => "things played",
    }
}

fn rewatch_label(media_type: &str, count: usize) -> String {
    let one = count == 1;
    let (noun, note) = match media_type {
        "music" => (
            if one { "replay" } else { "replays" },
            "worth a second listen",
        ),
        "movie" | "series" => (
            if one { "rewatch" } else { "rewatches" },
            "worth seeing twice",
        ),
        _ => (
            if one { "repeat" } else { "repeats" },
            "worth going back to",
        ),
    };
    format!("{noun}, {note}")
}

fn cards(
    plays: &[(Play, Item)],
    totals: &Totals,
    rhythm: &[RhythmRow],
    period: &Period,
    media_type: &str,
) -> Cards {
    let busiest = rhythm
        .iter()
        .filter(|r| r.total > 0.0)
        .max_by(|a, b| a.total.total_cmp(&b.total))
        .map(|r| Busiest {
            label: r.label.clone(),
            hours: rounded(r.total),
            context: match period.kind.as_str() {
                "week" | "month" => "busiest day",
                "all" => "busiest year",
                _ => "busiest month",
            },
        });
    let weeks = match (period.from, period.to) {
        (Some(from), Some(to)) => {
            let seconds = to.duration_since(from).as_secs_f64();
            (seconds / (7.0 * 86_400.0)).ceil().clamp(1.0, 10_000.0)
        }
        _ => 1.0,
    };
    #[allow(clippy::cast_precision_loss)]
    let average_per_week = round1(plays.len() as f64 / weeks);
    Cards {
        different_titles: totals.unique_titles,
        rewatches: totals.rewatches,
        rewatch_label: rewatch_label(media_type, totals.rewatches),
        busiest,
        average_per_week,
    }
}

/// A rhythm bucket key: sortable, and labelled for display.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
enum Bucket {
    Month(i16, i8),
    Day(Date),
    Year(i16),
}

impl Bucket {
    fn label(&self, period: &str) -> String {
        match self {
            Self::Month(year, month) => {
                let name = MONTH_NAMES[usize::try_from(*month - 1).unwrap_or(0)];
                if period == "year" {
                    name.to_string()
                } else {
                    format!("{name} {year}")
                }
            }
            Self::Day(date) if period == "week" => date.strftime("%a").to_string(),
            Self::Day(date) => date.strftime("%b %-d").to_string(),
            Self::Year(year) => year.to_string(),
        }
    }
}

/// Hours per bucket (not play counts), so a month of movies outweighs a
/// month of short songs.
fn rhythm(plays: &[(Play, Item)], period: &Period) -> Vec<RhythmRow> {
    if plays.is_empty() {
        return Vec::new();
    }
    let dates: Vec<Date> = plays
        .iter()
        .filter_map(|(p, _)| p.local_date.parse().ok())
        .collect();
    let (Some(first), Some(last)) = (dates.iter().min().copied(), dates.iter().max().copied())
    else {
        return Vec::new();
    };
    let span_days = (last - first).get_days();
    let kind = period.kind.as_str();
    let bucket_of = |date: Date| match kind {
        "year" => Bucket::Month(date.year(), date.month()),
        "week" | "month" => Bucket::Day(date),
        "all" => Bucket::Year(date.year()),
        _ if span_days <= 90 => Bucket::Day(date),
        _ => Bucket::Month(date.year(), date.month()),
    };
    let today = period.today;
    let all_keys: Option<Vec<Bucket>> = match kind {
        "year" => Some((1..=12).map(|m| Bucket::Month(today.year(), m)).collect()),
        "week" | "month" => {
            let days = if kind == "week" { 6 } else { 29 };
            Some(
                (0..=days)
                    .rev()
                    .filter_map(|n| today.checked_sub(n.days()).ok())
                    .map(Bucket::Day)
                    .collect(),
            )
        }
        "all" => Some((first.year()..=last.year()).map(Bucket::Year).collect()),
        _ => None,
    };
    let mut sums: BTreeMap<Bucket, (f64, f64, f64)> = BTreeMap::new();
    for (play, item) in plays {
        let Ok(date) = play.local_date.parse::<Date>() else {
            continue;
        };
        let entry = sums.entry(bucket_of(date)).or_default();
        match item.media_type.as_str() {
            "episode" => entry.1 += hours(item),
            "track" | "music_video" => entry.2 += hours(item),
            _ => entry.0 += hours(item),
        }
    }
    let keys = all_keys.unwrap_or_else(|| sums.keys().cloned().collect());
    let mut rows: Vec<RhythmRow> = keys
        .iter()
        .map(|key| {
            let (movies, episodes, tracks) = sums.get(key).copied().unwrap_or_default();
            let label = key.label(kind);
            let mut parts = Vec::new();
            if rounded(movies + episodes) > 0 {
                parts.push(format!(
                    "{} of video",
                    pluralize_hours(rounded(movies + episodes))
                ));
            }
            if rounded(tracks) > 0 {
                parts.push(format!("{} of audio", pluralize_hours(rounded(tracks))));
            }
            let tooltip = if parts.is_empty() {
                label.clone()
            } else {
                format!("{label} • {}", parts.join(" / "))
            };
            RhythmRow {
                label,
                movies,
                episodes,
                tracks,
                total: movies + episodes + tracks,
                tooltip,
                peak: false,
            }
        })
        .collect();
    let peak = rows.iter().map(|r| r.total).fold(0.0, f64::max);
    for row in &mut rows {
        row.peak = peak > 0.0 && (row.total - peak).abs() < f64::EPSILON;
    }
    rows
}

fn level_for(count: usize, max: usize) -> u8 {
    if count == 0 || max == 0 {
        return 0;
    }
    #[allow(clippy::cast_precision_loss)]
    let ratio = count as f64 / max as f64;
    match ratio {
        r if r >= 0.75 => 4,
        r if r >= 0.5 => 3,
        r if r >= 0.25 => 2,
        _ => 1,
    }
}

/// Plays per local day over the last year, for the user's filter.
fn heatmap(
    conn: &Connection,
    user_id: i64,
    zone: &str,
    media_type: &str,
    period: &Period,
) -> Result<Heatmap> {
    let today = time::today(zone);
    let start = today.checked_sub(364.days())?;
    let mut sql =
        "SELECT plays.local_date, count(*) FROM plays JOIN items ON items.id = plays.item_id \
                   WHERE plays.user_id = ? AND plays.local_date >= ?"
            .to_string();
    let mut params = vec![
        SqlValue::Integer(user_id),
        SqlValue::Text(start.to_string()),
    ];
    if let Some(types) = media_filter(media_type) {
        sql.push_str(" AND items.media_type IN (");
        sql.push_str(&vec!["?"; types.len()].join(", "));
        sql.push(')');
        params.extend(types.into_iter().map(|t| SqlValue::Text(t.into())));
    }
    sql.push_str(" GROUP BY plays.local_date");
    let mut stmt = conn.prepare(&sql)?;
    let counts: HashMap<Date, usize> = stmt
        .query_map(rusqlite::params_from_iter(params), |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?
        .filter_map(|row| {
            let (day, count) = row.ok()?;
            Some((day.parse().ok()?, usize::try_from(count).ok()?))
        })
        .collect();
    let in_filter = |date: Date| {
        period.from_date.is_none_or(|from| date >= from)
            && period.to_date.is_none_or(|to| date <= to)
    };
    let filtered: Vec<(Date, usize)> = counts
        .iter()
        .filter(|(d, _)| in_filter(**d))
        .map(|(d, c)| (*d, *c))
        .collect();
    let max = filtered.iter().map(|(_, c)| *c).max().unwrap_or(0);
    let mut cells = Vec::new();
    let mut day = start;
    while day <= today {
        let inside = in_filter(day);
        let count = if inside {
            counts.get(&day).copied().unwrap_or(0)
        } else {
            0
        };
        cells.push(HeatCell {
            date: day,
            count,
            level: if inside { level_for(count, max) } else { 0 },
            in_filter: inside,
        });
        day = day.tomorrow()?;
    }
    let biggest_day = filtered
        .iter()
        .copied()
        .max_by(|a, b| a.1.cmp(&b.1).then(b.0.cmp(&a.0)));
    Ok(Heatmap {
        cells,
        days_with_plays: filtered.iter().filter(|(_, c)| *c > 0).count(),
        biggest_day,
    })
}

fn series_for(
    conn: &Connection,
    cache: &mut HashMap<String, Option<Item>>,
    external_id: &str,
) -> Result<Option<Item>> {
    if let Some(found) = cache.get(external_id) {
        return Ok(found.clone());
    }
    let found = Item::find_by_key(conn, "series", external_id)?;
    cache.insert(external_id.to_string(), found.clone());
    Ok(found)
}

/// Counts, highest first; ties keep first-seen order.
fn ranked<K: Clone + Eq + std::hash::Hash>(keys: impl Iterator<Item = K>) -> Vec<(K, usize)> {
    let mut order: Vec<K> = Vec::new();
    let mut counts: HashMap<K, usize> = HashMap::new();
    for key in keys {
        let count = counts.entry(key.clone()).or_default();
        if *count == 0 {
            order.push(key);
        }
        *count += 1;
    }
    let mut rows: Vec<(K, usize)> = order
        .into_iter()
        .map(|k| {
            let c = counts[&k];
            (k, c)
        })
        .collect();
    rows.sort_by_key(|row| std::cmp::Reverse(row.1));
    rows.truncate(10);
    rows
}

fn top_genres(
    conn: &Connection,
    plays: &[(Play, Item)],
    shows: &mut HashMap<String, Option<Item>>,
) -> Result<Vec<Genre>> {
    let rows = ranked(
        plays
            .iter()
            .filter_map(|(_, item)| item.genres().into_iter().next()),
    );
    let mut out = Vec::new();
    for (name, count) in rows {
        // A poster for the genre: one of its titles (a show for episodes).
        let mut sample = None;
        for (_, item) in plays
            .iter()
            .filter(|(_, i)| i.genres().first() == Some(&name))
        {
            let candidate = if item.media_type == "episode" {
                match &item.parent_external_id {
                    Some(parent) => series_for(conn, shows, parent)?,
                    None => None,
                }
            } else {
                Some(item.clone())
            };
            if let Some(candidate) = candidate
                && candidate
                    .poster_path
                    .as_deref()
                    .is_some_and(|p| !p.is_empty())
            {
                sample = Some(candidate);
                break;
            }
        }
        out.push(Genre {
            name,
            count,
            sample,
        });
    }
    Ok(out)
}

fn top_shows(
    conn: &Connection,
    plays: &[(Play, Item)],
    shows: &mut HashMap<String, Option<Item>>,
) -> Result<Vec<Show>> {
    let episodes: Vec<&Item> = plays
        .iter()
        .map(|(_, i)| i)
        .filter(|i| i.media_type == "episode")
        .collect();
    let rows = ranked(
        episodes
            .iter()
            .map(|i| i.parent_external_id.clone().unwrap_or_default()),
    );
    let mut out = Vec::new();
    for (parent, count) in rows {
        let sample = episodes
            .iter()
            .find(|i| i.parent_external_id.as_deref().unwrap_or_default() == parent);
        let name = sample
            .and_then(|i| i.meta_str("series_name"))
            .map_or_else(|| format!("Show {parent}"), String::from);
        out.push(Show {
            item: series_for(conn, shows, &parent)?,
            parent_external_id: parent,
            name,
            episode_count: count,
        });
    }
    Ok(out)
}

fn top_movies(plays: &[(Play, Item)]) -> Vec<Ranked> {
    let movies: Vec<&Item> = plays
        .iter()
        .map(|(_, i)| i)
        .filter(|i| i.media_type == "movie")
        .collect();
    ranked(movies.iter().map(|i| i.id))
        .into_iter()
        .filter_map(|(id, count)| {
            let item = movies.iter().find(|i| i.id == id)?;
            Some(Ranked {
                name: item.title.clone(),
                count,
                item: Some((*item).clone()),
                album: None,
            })
        })
        .collect()
}

fn rank_music(conn: &Connection, plays: &[(Play, Item)], key: &str) -> Result<Vec<Ranked>> {
    let rows = ranked(
        plays
            .iter()
            .filter(|(_, i)| i.media_type == "track")
            .filter_map(|(_, i)| i.meta_str(key).map(String::from)),
    );
    let mut out = Vec::new();
    for (external_id, count) in rows {
        let item = Item::first(conn, "WHERE external_id = ? ORDER BY id", [&external_id])?;
        out.push(Ranked {
            name: item
                .as_ref()
                .map_or_else(|| "Unknown".into(), |i| i.title.clone()),
            count,
            item,
            album: None,
        });
    }
    Ok(out)
}

fn top_tracks(conn: &Connection, plays: &[(Play, Item)]) -> Result<Vec<Ranked>> {
    let tracks: Vec<&Item> = plays
        .iter()
        .map(|(_, i)| i)
        .filter(|i| i.media_type == "track")
        .collect();
    let mut out = Vec::new();
    for (id, count) in ranked(tracks.iter().map(|i| i.id)) {
        let Some(track) = tracks.iter().find(|i| i.id == id) else {
            continue;
        };
        let album = match track.meta_str("album_external_id") {
            Some(album) => Item::first(conn, "WHERE external_id = ? ORDER BY id", [album])?,
            None => None,
        };
        out.push(Ranked {
            name: track.display_title(),
            count,
            item: Some((*track).clone()),
            album,
        });
    }
    Ok(out)
}

/// The people credited across plays (once per play), with the title they
/// were seen in most.
fn top_people(plays: &[(Play, Item)], credits: impl Fn(&Item) -> Vec<Value>) -> Vec<Person> {
    let mut order: Vec<String> = Vec::new();
    let mut counts: HashMap<String, usize> = HashMap::new();
    let mut profiles: HashMap<String, Option<String>> = HashMap::new();
    let mut titles: HashMap<String, Vec<(String, usize)>> = HashMap::new();
    for (_, item) in plays {
        let label = if item.media_type == "episode" {
            item.meta_str("series_name").unwrap_or("Show").to_string()
        } else {
            item.title.clone()
        };
        let mut seen = HashSet::new();
        for person in credits(item) {
            let Some(name) = person["name"].as_str() else {
                continue;
            };
            if !seen.insert(name.to_string()) {
                continue;
            }
            let count = counts.entry(name.to_string()).or_default();
            if *count == 0 {
                order.push(name.to_string());
            }
            *count += 1;
            let profile = profiles.entry(name.to_string()).or_default();
            if profile.is_none() {
                *profile = person["profile_path"].as_str().map(String::from);
            }
            let list = titles.entry(name.to_string()).or_default();
            match list.iter_mut().find(|(t, _)| *t == label) {
                Some((_, n)) => *n += 1,
                None => list.push((label.clone(), 1)),
            }
        }
    }
    let mut people: Vec<Person> = order
        .into_iter()
        .map(|name| Person {
            count: counts[&name],
            profile_path: profiles.get(&name).cloned().flatten(),
            top_item_title: titles
                .get(&name)
                .and_then(|list| {
                    list.iter()
                        .fold(None::<&(String, usize)>, |best, row| match best {
                            Some(b) if b.1 >= row.1 => Some(b),
                            _ => Some(row),
                        })
                })
                .map(|(t, _)| t.clone()),
            name,
        })
        .collect();
    people.sort_by_key(|p| std::cmp::Reverse(p.count));
    people.truncate(10);
    people
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use crate::models::User;
    use crate::models::item::Attrs;
    use crate::models::play::NewPlay;
    use serde_json::json;

    struct Fixture {
        conn: Connection,
        user: i64,
    }

    fn ago(hours: i64) -> Timestamp {
        time::now() - jiff::SignedDuration::from_hours(hours)
    }

    fn fixture() -> Fixture {
        let conn = db::open_in_memory().unwrap();
        let user = User::create(&conn, "fnando", None, "x").unwrap().id;
        let f = Fixture { conn, user };
        let drama = f.item("movie", "tmdb:1", "Drama", 120, json!({
            "genres": [{"name": "Drama"}],
            "credits": {"crew": [{"job": "Director", "name": "Nolan"}], "cast": [{"name": "DiCaprio"}]}
        }));
        let comedy = f.item(
            "movie",
            "tmdb:2",
            "Comedy",
            90,
            json!({"genres": [{"name": "Comedy"}]}),
        );
        f.play(drama.id, ago(24));
        f.play(drama.id, ago(48));
        f.play(comedy.id, ago(72));
        f
    }

    impl Fixture {
        fn item(
            &self,
            media_type: &str,
            key: &str,
            title: &str,
            runtime: i64,
            metadata: Value,
        ) -> Item {
            Item::upsert(
                &self.conn,
                media_type,
                key,
                &Attrs::new()
                    .text("title", Some(title))
                    .int("runtime", Some(runtime))
                    .metadata(&metadata),
            )
            .unwrap()
        }

        fn play(&self, item_id: i64, at: Timestamp) {
            Play::create(
                &self.conn,
                &NewPlay {
                    user_id: self.user,
                    item_id,
                    source: "manual".into(),
                    started_at: Some(at),
                    ..NewPlay::default()
                },
            )
            .unwrap();
        }

        fn stats(&self, media_type: &str, period: &str) -> Stats {
            compute(
                &self.conn,
                self.user,
                "UTC",
                media_type,
                resolve_period(period, None, None, "UTC"),
            )
            .unwrap()
        }

        fn music(&self) -> (Item, Item) {
            self.item("artist", "mbid:artist:a1", "Radiohead", 0, json!({}));
            let album = self.item("album", "mbid:release:r1", "OK Computer", 0, json!({}));
            let track = self.item(
                "track",
                "mbid:rt:t1",
                "Karma Police",
                4,
                json!({
                    "artist": "Radiohead", "artist_external_id": "mbid:artist:a1",
                    "album": "OK Computer", "album_external_id": "mbid:release:r1"
                }),
            );
            self.play(track.id, ago(1));
            self.play(track.id, ago(2));
            (album, track)
        }
    }

    #[test]
    fn totals_count_plays_titles_hours_and_rewatches() {
        let t = fixture().stats("all", "all").totals;
        assert_eq!(
            (t.plays, t.unique_titles, t.movies_count, t.episodes_count),
            (3, 2, 3, 0)
        );
        assert!((t.hours_watched - 5.5).abs() < 0.01);
        assert_eq!(t.rewatches, 1);
    }

    #[test]
    fn the_hero_reads_as_a_sentence() {
        let f = fixture();
        let s = f.stats("all", "all");
        assert_eq!(
            s.headline.hours_sentence,
            "6 hours in front of the screen, start to finish."
        );
        assert_eq!(s.headline.big_number, 3);
        assert_eq!(s.headline.unit, "things played");
        let track = f.item("track", "mbid:z", "Long One", 90, json!({}));
        f.play(track.id, ago(1));
        assert_eq!(
            f.stats("all", "all").headline.hours_sentence,
            "6 hours in front of the screen and 2 hours of music."
        );
        assert_eq!(
            hero_sentence(30.0, 0.0),
            "30 hours in front of the screen. That's 1 day and 6 hours of stories, start to finish."
        );
        assert_eq!(hero_sentence(0.0, 3.0), "3 hours of music, in your ears.");
        assert_eq!(hero_sentence(0.0, 0.0), "No time logged yet.");
    }

    #[test]
    fn rhythm_tooltips_break_down_hours() {
        let s = fixture().stats("all", "all");
        let busiest = s
            .rhythm
            .iter()
            .max_by(|a, b| a.total.total_cmp(&b.total))
            .unwrap();
        assert!(
            busiest.tooltip.contains(" • ") && busiest.tooltip.contains("hours of video"),
            "{}",
            busiest.tooltip
        );
    }

    #[test]
    fn a_year_has_twelve_monthly_buckets() {
        let s = fixture().stats("all", "year");
        assert_eq!(s.rhythm.len(), 12);
        assert_eq!(s.rhythm[0].label, "Jan");
    }

    #[test]
    fn a_week_has_seven_daily_buckets_ending_today() {
        let s = fixture().stats("all", "week");
        assert_eq!(s.rhythm.len(), 7);
        assert_eq!(s.cards.busiest.as_ref().unwrap().context, "busiest day");
    }

    #[test]
    fn genres_people_and_shows_rank_highest_first() {
        let f = fixture();
        let s = f.stats("all", "all");
        let genres: Vec<(&str, usize)> = s
            .top_genres
            .iter()
            .map(|g| (g.name.as_str(), g.count))
            .collect();
        assert_eq!(genres, [("Drama", 2), ("Comedy", 1)]);
        assert_eq!(
            s.top_directors[0],
            Person {
                name: "Nolan".into(),
                count: 2,
                profile_path: None,
                top_item_title: Some("Drama".into())
            }
        );
        assert_eq!(s.top_cast[0].name, "DiCaprio");
        assert_eq!(s.top_cast[0].top_item_title.as_deref(), Some("Drama"));

        let ep = f.item(
            "episode",
            "tmdb:ep",
            "Pilot",
            42,
            json!({"series_name": "Lost"}),
        );
        Item::update(
            &f.conn,
            ep.id,
            &Attrs::new().text("parent_external_id", Some("tmdb:99")),
        )
        .unwrap();
        f.play(ep.id, ago(1));
        let shows = f.stats("all", "all").top_shows;
        assert_eq!(
            (shows[0].name.as_str(), shows[0].episode_count),
            ("Lost", 1)
        );
    }

    #[test]
    fn the_media_filter_narrows_everything() {
        let f = fixture();
        let ep = f.item("episode", "tmdb:ep", "Ep", 30, json!({}));
        f.play(ep.id, ago(1));
        assert_eq!(f.stats("movie", "all").totals.plays, 3);
        assert_eq!(f.stats("series", "all").totals.plays, 1);
        assert_eq!(f.stats("movie", "all").headline.unit, "things watched");
    }

    #[test]
    fn music_ranks_artists_albums_and_tracks_and_counts_as_listening() {
        let f = fixture();
        let (album, _) = f.music();
        let video = f.item(
            "music_video",
            "youtube:mv1",
            "Creep",
            4,
            json!({"artist": "Radiohead"}),
        );
        f.play(video.id, ago(1));

        let s = f.stats("music", "all");
        assert_eq!(s.totals.plays, 3);
        assert_eq!(s.headline.unit, "listens");
        assert!(s.top_movies.is_empty());
        assert_eq!(
            (s.top_artists[0].name.as_str(), s.top_artists[0].count),
            ("Radiohead", 2)
        );
        assert_eq!(s.top_albums[0].name, "OK Computer");
        assert_eq!(s.top_tracks[0].item.as_ref().unwrap().title, "Karma Police");
        assert_eq!(s.top_tracks[0].album.as_ref().unwrap().id, album.id);
        assert!(s.cards.rewatch_label.contains("worth a second listen"));

        let all = f.stats("all", "all");
        assert!((all.totals.hours_watched - 5.5).abs() < 0.01);
        assert_eq!(all.totals.movies_count, 3);
        assert_eq!(all.totals.tracks_count, 3);
        assert!(all.totals.listening_hours > 0.0);
        let movie_hours: f64 = all.rhythm.iter().map(|r| r.movies).sum();
        assert!((movie_hours - 5.5).abs() < 0.01);
        assert!(all.rhythm.iter().map(|r| r.tracks).sum::<f64>() > 0.0);
        assert!(all.cards.rewatch_label.contains("worth going back to"));
        assert!(
            f.stats("movie", "all")
                .cards
                .rewatch_label
                .contains("worth seeing twice")
        );
    }

    #[test]
    fn the_heatmap_covers_a_year_and_finds_the_biggest_day() {
        let s = fixture().stats("all", "year");
        assert_eq!(s.heatmap.cells.len(), 365);
        assert!(s.heatmap.days_with_plays >= 1);
        assert!(s.heatmap.biggest_day.is_some());
    }
}
