//! The stats page.

use askama::Template;
use axum::Router;
use axum::extract::Query;
use axum::routing::get;
use jiff::civil::{Date, Weekday};
use serde::Deserialize;

use super::helpers::{self, h};
use super::{Ctx, Page, Result, State, media, render};
use crate::models::Item;
use crate::services::stats::{self, Stats};
use crate::services::streaks::{self, Summary};

pub fn routes() -> Router<State> {
    Router::new().route("/stats", get(index))
}

fn plural(n: i64, word: &str) -> String {
    helpers::pluralize(n, word, None, true)
}

fn n(value: usize) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

pub struct Segment {
    pub class: &'static str,
    pub dasharray: String,
    pub dashoffset: String,
    pub count_label: String,
    pub pct: i64,
}

pub struct Hero {
    pub period_label: String,
    pub big_number: usize,
    pub unit: &'static str,
    pub sentence: String,
    pub aria: String,
    pub segments: Vec<Segment>,
}

#[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
fn hero(stats: &Stats) -> Hero {
    let t = &stats.totals;
    let raw: Vec<(&'static str, &'static str, usize, f64)> = [
        ("movies", "movie", t.movies_count, t.movies_hours),
        ("series", "episode", t.episodes_count, t.episodes_hours),
        ("music", "track", t.tracks_count, t.listening_hours),
    ]
    .into_iter()
    .filter(|s| s.2 > 0)
    .collect();
    // Weigh by time spent, not play counts (a movie dwarfs a song); fall back
    // to counts when no runtimes are known.
    let total_hours: f64 = raw.iter().map(|s| s.3).sum();
    let weigh = |s: &(&str, &str, usize, f64)| if total_hours > 0.0 { s.3 } else { s.2 as f64 };
    let total_weight: f64 = raw.iter().map(weigh).sum();
    let gap = if raw.len() > 1 { 1.5 } else { 0.0 };
    let mut cursor = 0.0;
    let segments: Vec<Segment> = raw
        .iter()
        .map(|s| {
            let pct = if total_weight > 0.0 {
                weigh(s) / total_weight * 100.0
            } else {
                0.0
            };
            let len = (pct - gap).max(0.0);
            let segment = Segment {
                class: s.0,
                dasharray: format!("{} {}", round2(len), round2(100.0 - len)),
                dashoffset: format!("{}", round2(-cursor - gap / 2.0)),
                count_label: plural(n(s.2), s.1),
                pct: pct.round() as i64,
            };
            cursor += pct;
            segment
        })
        .collect();
    let aria = segments
        .iter()
        .zip(&raw)
        .map(|(seg, s)| format!("{}% {}s", seg.pct, s.1))
        .collect::<Vec<_>>()
        .join(", ");
    Hero {
        period_label: stats.period.label.clone(),
        big_number: stats.headline.big_number,
        unit: stats.headline.unit,
        sentence: stats.headline.hours_sentence.clone(),
        aria,
        segments,
    }
}

fn round2(value: f64) -> f64 {
    let rounded = (value * 100.0).round() / 100.0;
    if rounded == 0.0 { 0.0 } else { rounded }
}

pub struct CardsView {
    pub different_titles: usize,
    pub titles_label: String,
    pub rewatches: usize,
    pub rewatch_label: String,
    pub busiest: Option<(String, String)>,
    pub average: String,
    pub average_label: String,
}

fn cards(stats: &Stats) -> CardsView {
    let c = &stats.cards;
    let average = if c.average_per_week.fract() == 0.0 {
        format!("{:.1}", c.average_per_week)
    } else {
        c.average_per_week.to_string()
    };
    CardsView {
        different_titles: c.different_titles,
        titles_label: helpers::pluralize(n(c.different_titles), "different title", None, false),
        rewatches: c.rewatches,
        rewatch_label: c.rewatch_label.clone(),
        busiest: c.busiest.as_ref().map(|b| {
            (
                b.label.clone(),
                format!("{} · {}", b.context, plural(b.hours, "hour")),
            )
        }),
        average,
        average_label: if (c.average_per_week - 1.0).abs() < f64::EPSILON {
            "play"
        } else {
            "plays"
        }
        .into(),
    }
}

pub struct Column {
    pub label: String,
    pub tooltip: String,
    pub peak: bool,
    pub movies: f64,
    pub series: f64,
    pub music: f64,
}

pub struct Rhythm {
    pub busiest_line: Option<String>,
    pub has_music: bool,
    pub columns: Vec<Column>,
}

#[allow(clippy::cast_possible_truncation)]
fn rhythm(stats: &Stats) -> Rhythm {
    let max = stats.rhythm.iter().map(|r| r.total).fold(0.0, f64::max);
    let pct = |v: f64| {
        if v > 0.0 && max > 0.0 {
            (v / max * 1000.0).round() / 10.0
        } else {
            0.0
        }
    };
    let busiest = stats
        .rhythm
        .iter()
        .filter(|r| r.total > 0.0)
        .max_by(|a, b| a.total.total_cmp(&b.total));
    Rhythm {
        busiest_line: busiest.map(|b| {
            format!(
                "{} was your busiest month, with {}.",
                b.label,
                plural(b.total.round() as i64, "hour")
            )
        }),
        has_music: stats.rhythm.iter().any(|r| r.tracks > 0.0),
        columns: if max == 0.0 {
            Vec::new()
        } else {
            stats
                .rhythm
                .iter()
                .map(|r| Column {
                    label: r.label.clone(),
                    tooltip: r.tooltip.clone(),
                    peak: r.peak && r.total > 0.0,
                    movies: pct(r.movies),
                    series: pct(r.episodes),
                    music: pct(r.tracks),
                })
                .collect()
        },
    }
}

pub struct Heat {
    pub period_label: String,
    pub days_label: String,
    pub biggest_line: Option<String>,
    pub weeks: usize,
    pub month_labels: Vec<String>,
    /// `None` pads the first week so columns start on Sunday.
    pub cells: Vec<Option<(u8, bool, String)>>,
}

fn heat(stats: &Stats) -> Heat {
    let hm = &stats.heatmap;
    let offset = hm.cells.first().map_or(0, |c| {
        usize::try_from(c.date.weekday().to_sunday_zero_offset()).unwrap_or(0)
    });
    let mut padded: Vec<Option<&stats::HeatCell>> = vec![None; offset];
    padded.extend(hm.cells.iter().map(Some));
    let weeks: Vec<&[Option<&stats::HeatCell>]> = padded.chunks(7).collect();
    let firsts: Vec<Option<Date>> = weeks
        .iter()
        .map(|w| w.iter().flatten().next().map(|c| c.date))
        .collect();
    let month_labels = firsts
        .iter()
        .enumerate()
        .map(|(i, first)| match first {
            Some(day) => {
                let prev = if i > 0 { firsts[i - 1] } else { None };
                if prev.is_none_or(|p| p.month() != day.month()) {
                    day.strftime("%b").to_string()
                } else {
                    String::new()
                }
            }
            None => String::new(),
        })
        .collect();
    Heat {
        period_label: stats.period.label.clone(),
        days_label: plural(n(hm.days_with_plays), "day"),
        biggest_line: hm.biggest_day.map(|(date, count)| {
            format!(
                "Biggest day: {}, with {}.",
                date.strftime("%a, %b %-d"),
                plural(n(count), "play")
            )
        }),
        weeks: weeks.len(),
        month_labels,
        cells: padded
            .iter()
            .map(|cell| {
                cell.map(|c| {
                    let title = if c.in_filter {
                        format!(
                            "{}: {}",
                            c.date.strftime("%a, %b %-d, %Y"),
                            plural(n(c.count), "play")
                        )
                    } else {
                        format!("{} (outside filter)", c.date.strftime("%a, %b %-d, %Y"))
                    };
                    (c.level, !c.in_filter, title)
                })
            })
            .collect(),
    }
}

pub struct StripCell {
    pub classes: String,
    pub title: String,
    pub label: String,
    pub watched: bool,
    pub today: bool,
}

pub struct StreakFoot {
    pub best_label: &'static str,
    pub best_length: String,
    pub range: String,
    pub pct: i64,
    pub text: String,
}

pub struct StreakView {
    pub card_class: &'static str,
    pub record: bool,
    pub current: i64,
    pub days_word: String,
    pub line: String,
    pub strip: Vec<StripCell>,
    pub foot: Option<StreakFoot>,
}

fn parse(day: &str) -> Option<Date> {
    day.parse().ok()
}

fn range(start: &str, end: &str) -> String {
    let (Some(s), Some(e)) = (parse(start), parse(end)) else {
        return format!("{start} – {end}");
    };
    if s == e {
        s.strftime("%b %-d, %Y").to_string()
    } else if s.year() == e.year() && s.month() == e.month() {
        format!("{}–{}", s.strftime("%b %-d"), e.strftime("%-d, %Y"))
    } else if s.year() == e.year() {
        format!("{} – {}", s.strftime("%b %-d"), e.strftime("%b %-d, %Y"))
    } else {
        format!(
            "{} – {}",
            s.strftime("%b %-d, %Y"),
            e.strftime("%b %-d, %Y")
        )
    }
}

#[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
fn streak(scope: &Summary, media_type: &str) -> StreakView {
    let current = scope.current;
    let state = streak_state(scope);
    let line = streak_line(scope, media_type);
    let strip = scope
        .strip
        .iter()
        .map(|cell| {
            let mut classes = vec!["streak-day"];
            if cell.in_streak {
                classes.push("is-streak");
            }
            if cell.watched && !cell.in_streak {
                classes.push("is-watched");
            }
            if cell.today {
                classes.push("is-today");
            }
            if cell.today && !cell.watched {
                classes.push("is-pending");
            }
            let title = format!(
                "{}{}",
                cell.date.strftime("%a, %b %-d"),
                if cell.today { " (today)" } else { "" }
            );
            StripCell {
                classes: classes.join(" "),
                label: if cell.today {
                    "Today".into()
                } else {
                    weekday_letter(cell.date.weekday()).into()
                },
                title,
                watched: cell.watched,
                today: cell.today,
            }
        })
        .collect();
    let foot = streak_foot(
        scope,
        state == Phase::Empty,
        state == Phase::Record,
        state == Phase::Active,
    );
    StreakView {
        card_class: match state {
            Phase::Record => " streak-card--record",
            Phase::Ended | Phase::Empty => " streak-card--idle",
            Phase::Active => "",
        },
        record: state == Phase::Record,
        current,
        days_word: helpers::pluralize(current, "day", None, false),
        line,
        strip,
        foot,
    }
}

#[derive(PartialEq)]
enum Phase {
    Empty,
    Record,
    Active,
    Ended,
}

fn streak_state(scope: &Summary) -> Phase {
    match &scope.longest {
        None => Phase::Empty,
        Some(_) if scope.is_record => Phase::Record,
        Some(_) if scope.current > 0 => Phase::Active,
        Some(_) => Phase::Ended,
    }
}

/// The sentence under the streak count.
fn streak_line(scope: &Summary, media_type: &str) -> String {
    let current = scope.current;
    let state = streak_state(scope);
    let phrase = match media_type {
        "movie" => "watched a movie",
        "series" => "watched a show",
        "music" => "listened to music",
        _ => "watched something",
    };
    match state {
        Phase::Record => format!(
            "{} in a row: your longest streak ever. Keep it rolling.",
            plural(current, "day")
        ),
        Phase::Active => format!(
            "You&#8217;ve {phrase} {} in a row. Nice!",
            plural(current, "day")
        ),
        Phase::Ended => {
            let last = scope.last_streak.as_ref().expect("a streak ended");
            let was_record = scope
                .longest
                .as_ref()
                .is_some_and(|l| l.length == last.length);
            format!(
                "Your {} streak ended on {}{}. Watch something today to start a new one.",
                plural(last.length, "day"),
                parse(&last.end)
                    .map(|d| d.strftime("%b %-d").to_string())
                    .unwrap_or_default(),
                if was_record {
                    ", and it was your best yet"
                } else {
                    ""
                }
            )
        }
        Phase::Empty => {
            "No streak yet. Every day you watch something adds a day to your streak.".into()
        }
    }
}

#[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
fn streak_foot(scope: &Summary, empty: bool, record: bool, active: bool) -> Option<StreakFoot> {
    let current = scope.current;
    match (empty, record, &scope.longest) {
        (true, _, _) | (_, _, None) => None,
        (_, true, _) => Some(if let Some(best) = &scope.previous_best {
            {
                let gained = current - best.length;
                StreakFoot {
                    best_label: "Previous best:",
                    best_length: plural(best.length, "day"),
                    range: range(&best.start, &best.end),
                    pct: 100,
                    text: if gained > 0 {
                        format!("{} past your old record", plural(gained, "day"))
                    } else {
                        "You matched your best ever".into()
                    },
                }
            }
        } else {
            {
                let range_of = scope.current_range.as_ref();
                StreakFoot {
                    best_label: "Longest streak:",
                    best_length: plural(current, "day"),
                    range: range_of
                        .map(|r| range(&r.start, &r.end))
                        .unwrap_or_default(),
                    pct: 100,
                    text: "Your longest streak yet".into(),
                }
            }
        }),
        (_, _, Some(longest)) => StreakFoot {
            best_label: "Longest streak:",
            best_length: plural(longest.length, "day"),
            range: range(&longest.start, &longest.end),
            pct: if active {
                ((current as f64 * 100.0 / longest.length as f64).round() as i64).min(100)
            } else {
                0
            },
            text: if active {
                format!("{} to beat it", plural(longest.length - current, "day"))
            } else {
                "Start again today to chase it".into()
            },
        }
        .into(),
    }
}

fn weekday_letter(day: Weekday) -> &'static str {
    match day {
        Weekday::Monday => "M",
        Weekday::Tuesday | Weekday::Thursday => "T",
        Weekday::Wednesday => "W",
        Weekday::Friday => "F",
        Weekday::Saturday | Weekday::Sunday => "S",
    }
}

pub struct RankHero {
    pub name_html: String,
    pub meta: String,
    pub poster_url: Option<String>,
}

pub struct RankRow {
    pub name_html: String,
    pub count_label: String,
    pub poster_url: Option<String>,
    pub width: i64,
}

pub struct RankList {
    pub title: &'static str,
    pub subtitle: Option<String>,
    pub variant: &'static str,
    pub hero: RankHero,
    pub rows: Vec<RankRow>,
}

/// One ranked entry before formatting: name HTML, count, poster.
struct Entry {
    name_html: String,
    count: usize,
    poster: Option<String>,
}

#[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
fn rank_list(
    title: &'static str,
    subtitle: Option<String>,
    variant: &'static str,
    unit: &str,
    hero_meta: Option<String>,
    entries: Vec<Entry>,
) -> Option<RankList> {
    let mut entries = entries.into_iter();
    let first = entries.next()?;
    let rest: Vec<Entry> = entries.collect();
    let total = (first.count + rest.iter().map(|e| e.count).sum::<usize>()).max(1);
    Some(RankList {
        title,
        subtitle,
        variant,
        hero: RankHero {
            meta: hero_meta.unwrap_or_else(|| plural(n(first.count), unit)),
            name_html: first.name_html,
            poster_url: first.poster,
        },
        rows: rest
            .into_iter()
            .map(|e| RankRow {
                width: (e.count as f64 / total as f64 * 100.0).round() as i64,
                count_label: plural(n(e.count), unit),
                name_html: e.name_html,
                poster_url: e.poster,
            })
            .collect(),
    })
}

fn poster(item: Option<&Item>) -> Option<String> {
    item.map(media::poster_url)
}

#[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
fn lists(stats: &Stats) -> (Vec<RankList>, Vec<RankList>) {
    let mut before = Vec::new();
    let genres = &stats.top_genres;
    if let Some(top) = genres.first() {
        let total: usize = genres.iter().map(|g| g.count).sum();
        let pct = if total > 0 {
            (top.count as f64 / total as f64 * 100.0).round() as i64
        } else {
            0
        };
        let subtitle = (genres.len() >= 2).then(|| {
            format!(
                "Mostly {}, with a soft spot for {}.",
                genres[0].name.to_lowercase(),
                genres[1].name.to_lowercase()
            )
        });
        let entries = genres
            .iter()
            .map(|g| Entry {
                name_html: h(&g.name),
                count: g.count,
                poster: poster(g.sample.as_ref()),
            })
            .collect();
        let mut list = rank_list(
            "Your taste",
            subtitle,
            "taste",
            "title",
            Some(format!(
                "{} · in {pct}% of everything you watched",
                plural(n(top.count), "play")
            )),
            entries,
        );
        if let Some(list) = &mut list {
            list.hero.poster_url = poster(top.sample.as_ref());
        }
        before.extend(list);
    }
    before.extend(rank_list(
        "Shows you couldn't stop",
        Some("The series you kept coming back to.".into()),
        "shows",
        "episode",
        None,
        stats
            .top_shows
            .iter()
            .map(|s| Entry {
                name_html: h(&s.name),
                count: s.episode_count,
                poster: poster(s.item.as_ref()),
            })
            .collect(),
    ));

    let music = |list: &[stats::Ranked], with_album: bool| -> Vec<Entry> {
        list.iter()
            .map(|r| Entry {
                name_html: media::item_link(r.item.as_ref(), &r.name),
                count: r.count,
                poster: if with_album {
                    poster(r.album.as_ref().or(r.item.as_ref()))
                } else {
                    poster(r.item.as_ref())
                },
            })
            .collect()
    };
    let mut after = Vec::new();
    after.extend(rank_list(
        "On heavy rotation",
        Some("The artists you kept coming back to.".into()),
        "artists",
        "play",
        None,
        music(&stats.top_artists, false),
    ));
    after.extend(rank_list(
        "Albums on repeat",
        Some("The records that soundtracked your days.".into()),
        "albums",
        "play",
        None,
        music(&stats.top_albums, false),
    ));
    after.extend(rank_list(
        "Songs you couldn't skip",
        Some("The tracks you played the most.".into()),
        "tracks",
        "play",
        None,
        music(&stats.top_tracks, true),
    ));
    (before, after)
}

pub struct PersonView {
    pub name: String,
    pub initials: String,
    pub count: usize,
    pub appearances: String,
    pub profile_path: Option<String>,
    pub top_item_title: Option<String>,
}

pub struct PeopleGrid {
    pub title: &'static str,
    pub subtitle: &'static str,
    pub variant: &'static str,
    pub people: Vec<PersonView>,
}

fn people(
    title: &'static str,
    subtitle: &'static str,
    variant: &'static str,
    list: &[stats::Person],
) -> PeopleGrid {
    PeopleGrid {
        title,
        subtitle,
        variant,
        people: list
            .iter()
            .map(|p| PersonView {
                initials: p
                    .name
                    .split_whitespace()
                    .filter_map(|w| w.chars().next())
                    .take(2)
                    .collect::<String>()
                    .to_uppercase(),
                name: p.name.clone(),
                count: p.count,
                appearances: plural(n(p.count), "appearance"),
                profile_path: p.profile_path.clone(),
                top_item_title: p.top_item_title.clone(),
            })
            .collect(),
    }
}

#[derive(Template)]
#[template(path = "stats/index.html")]
struct Index {
    page: Page,
    periods: Vec<(&'static str, &'static str)>,
    media_types: Vec<(&'static str, &'static str)>,
    period: String,
    media_type: String,
    hero: Hero,
    cards: CardsView,
    rhythm: Rhythm,
    streak: StreakView,
    heat: Heat,
    lists_before: Vec<RankList>,
    people: Vec<PeopleGrid>,
    lists_after: Vec<RankList>,
}

#[derive(Deserialize, Default)]
struct StatsQuery {
    #[serde(rename = "type")]
    kind: Option<String>,
    period: Option<String>,
    from: Option<String>,
    to: Option<String>,
}

async fn index(ctx: Ctx, Query(query): Query<StatsQuery>) -> Result {
    let media_type = match query.kind.as_deref() {
        Some(k @ ("movie" | "series" | "music")) => k.to_string(),
        _ => "all".to_string(),
    };
    let period_kind = match query.period.as_deref() {
        Some(p @ ("week" | "month" | "all" | "custom")) => p.to_string(),
        _ => "year".to_string(),
    };
    let user = ctx.user().clone();
    let (stats, streaks) = {
        let media_type = media_type.clone();
        let period_kind = period_kind.clone();
        ctx.blocking(move |conn| {
            let period = stats::resolve_period(
                &period_kind,
                query.from.as_deref(),
                query.to.as_deref(),
                &user.timezone,
            );
            let today = period.today;
            let stats = stats::compute(conn, user.id, &user.timezone, &media_type, period)?;
            let streaks = streaks::get(conn, user.id, today)?;
            Ok((stats, streaks))
        })
        .await?
    };
    let scope = if media_type == "all" {
        &streaks.overall
    } else {
        streaks.group(&media_type).unwrap_or(&streaks.overall)
    };
    let (lists_before, lists_after) = lists(&stats);
    render(&Index {
        page: ctx.page("Stats"),
        periods: vec![
            ("week", "Last 7 days"),
            ("month", "Last 30 days"),
            ("year", "This year"),
            ("all", "All time"),
        ],
        media_types: vec![
            ("all", "All"),
            ("movie", "Movies"),
            ("series", "Series"),
            ("music", "Music"),
        ],
        hero: hero(&stats),
        cards: cards(&stats),
        rhythm: rhythm(&stats),
        streak: streak(scope, &media_type),
        heat: heat(&stats),
        people: vec![
            people(
                "Familiar faces",
                "The cast you spent the most time with.",
                "cast",
                &stats.top_cast,
            ),
            people(
                "Behind the camera",
                "Directors and creators you keep coming back to.",
                "crew",
                &stats.top_directors,
            ),
        ],
        lists_before,
        lists_after,
        period: period_kind,
        media_type,
    })
}
