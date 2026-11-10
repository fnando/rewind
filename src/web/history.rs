//! History: plays grouped by local day, a few days per page; logging and
//! removing a watch by hand.

use askama::Template;
use axum::Router;
use axum::extract::{Form, Path, Query};
use axum::http::{HeaderMap, header};
use axum::routing::{delete, get};
use jiff::Timestamp;
use jiff::civil::Date;
use rusqlite::Connection;
use rusqlite::types::Value as SqlValue;
use serde::Deserialize;

use super::cards::{self, Entry};
use super::{AppError, Ctx, Page, Result, State, helpers, redirect, render};
use crate::models::play::{MUSIC_MEDIA_TYPES, NewPlay, Play};
use crate::models::{Item, User};
use crate::time;

/// Days of activity per page, however far apart they fall.
pub const DAYS_PER_PAGE: usize = 2;

pub fn routes() -> Router<State> {
    Router::new()
        .route("/", get(|| async { redirect("/history") }))
        .route("/history", get(index).post(create))
        .route("/history/{id}", delete(destroy))
}

pub struct Day {
    pub id: String,
    pub label: String,
    pub meta: String,
    pub entries: Vec<Entry>,
}

#[derive(Template)]
#[template(path = "history/index.html")]
struct Index {
    page: Page,
    kind: String,
    days: Vec<Day>,
    prev_url: Option<String>,
    next_url: Option<String>,
}

#[derive(Deserialize, Default)]
struct IndexQuery {
    #[serde(rename = "type")]
    kind: Option<String>,
    page: Option<String>,
}

fn page_url(kind: &str, page: usize) -> String {
    let mut pairs = Vec::new();
    if kind != "all" {
        pairs.push(("type", kind.to_string()));
    }
    if page > 1 {
        pairs.push(("page", page.to_string()));
    }
    format!("/history{}", helpers::query_string(&pairs))
}

/// The `AND items.media_type IN (…)` filter for a type, and its values.
fn type_filter(kind: &str) -> (String, Vec<SqlValue>) {
    let types: Vec<&str> = match kind {
        "all" => return (String::new(), Vec::new()),
        // The "Music" tab covers music videos too.
        "track" => MUSIC_MEDIA_TYPES.to_vec(),
        other => vec![other],
    };
    let marks = vec!["?"; types.len()].join(", ");
    (
        format!(" AND items.media_type IN ({marks})"),
        types
            .into_iter()
            .map(|t| SqlValue::Text(t.into()))
            .collect(),
    )
}

struct Loaded {
    days: Vec<Day>,
    has_next: bool,
}

fn load(
    conn: &Connection,
    user: &User,
    csrf_tag: &str,
    kind: &str,
    page: usize,
) -> anyhow::Result<Loaded> {
    let (filter, values) = type_filter(kind);
    let mut params = vec![SqlValue::Integer(user.id)];
    params.extend(values.clone());
    params.push(SqlValue::Integer(i64::try_from(DAYS_PER_PAGE + 1)?));
    params.push(SqlValue::Integer(i64::try_from(
        (page - 1) * DAYS_PER_PAGE,
    )?));
    let window: Vec<String> = {
        let mut stmt = conn.prepare(&format!(
            "SELECT DISTINCT plays.local_date FROM plays JOIN items ON items.id = plays.item_id \
             WHERE plays.user_id = ?{filter} ORDER BY plays.local_date DESC LIMIT ? OFFSET ?"
        ))?;
        stmt.query_map(rusqlite::params_from_iter(params), |row| row.get(0))?
            .collect::<rusqlite::Result<_>>()?
    };
    let has_next = window.len() > DAYS_PER_PAGE;
    let window: Vec<String> = window.into_iter().take(DAYS_PER_PAGE).collect();
    if window.is_empty() {
        return Ok(Loaded {
            days: Vec::new(),
            has_next: false,
        });
    }

    let mut params = vec![SqlValue::Integer(user.id)];
    params.extend(values);
    let marks = vec!["?"; window.len()].join(", ");
    params.extend(window.iter().map(|d| SqlValue::Text(d.clone())));
    let plays = cards::plays_with_items(
        conn,
        &format!(
            "WHERE plays.user_id = ?{filter} AND plays.local_date IN ({marks}) \
             ORDER BY plays.started_at DESC, plays.id DESC"
        ),
        rusqlite::params_from_iter(params),
    )?;
    let ctx = cards::Context::load(
        conn,
        user.id,
        &user.timezone,
        &user.rating_style,
        csrf_tag,
        &plays,
    )?;
    let today = time::today(&user.timezone);

    let days = window
        .iter()
        .map(|day| {
            let day_plays: Vec<(Play, Item)> = plays
                .iter()
                .filter(|(p, _)| &p.local_date == day)
                .cloned()
                .collect();
            let date: Option<Date> = day.parse().ok();
            let label = date.map_or_else(|| day.clone(), |d| helpers::day_label(d, today));
            let count = helpers::pluralize(
                i64::try_from(day_plays.len()).unwrap_or(0),
                "play",
                None,
                true,
            );
            // Only prefix the date when the label is relative, so it isn't
            // repeated on both lines.
            let meta = match date {
                Some(d) if label == "Today" || label == "Yesterday" => {
                    format!("{} · {count}", d.strftime("%A, %B %-d"))
                }
                _ => count,
            };
            Day {
                id: day.clone(),
                label,
                meta,
                entries: cards::entries(&ctx, &day_plays),
            }
        })
        .collect();
    Ok(Loaded { days, has_next })
}

async fn index(ctx: Ctx, Query(query): Query<IndexQuery>) -> Result {
    let kind = match query.kind.as_deref() {
        Some(k @ ("movie" | "episode" | "track")) => k.to_string(),
        _ => "all".to_string(),
    };
    let number = query
        .page
        .as_deref()
        .and_then(|p| p.parse::<usize>().ok())
        .unwrap_or(1)
        .max(1);
    let page = ctx.page("History");
    let user = ctx.user().clone();
    let csrf_tag = page.csrf_tag();
    let loaded = {
        let kind = kind.clone();
        ctx.blocking(move |conn| Ok(load(conn, &user, &csrf_tag, &kind, number)?))
            .await?
    };
    render(&Index {
        page,
        prev_url: (number > 1).then(|| page_url(&kind, number - 1)),
        next_url: loaded.has_next.then(|| page_url(&kind, number + 1)),
        kind,
        days: loaded.days,
    })
}

/// When a hand-logged watch happened: a wall-clock time in the user's zone,
/// as UTC. Blank means now; it can't be in the future (a minute of slack,
/// since the form defaults to "now").
pub fn manual_started_at(
    value: Option<&str>,
    zone: &str,
) -> std::result::Result<Timestamp, AppError> {
    let raw = value.unwrap_or_default().trim();
    if raw.is_empty() {
        return Ok(time::now());
    }
    let at = time::local_to_utc(raw, zone)
        .ok_or_else(|| AppError::BadRequest("Invalid date and time".into()))?;
    let limit = time::now()
        .checked_add(jiff::SignedDuration::from_secs(60))
        .map_err(anyhow::Error::from)?;
    if at > limit {
        return Err(AppError::Unprocessable(
            "A watch can't be in the future".into(),
        ));
    }
    Ok(at)
}

#[derive(Deserialize)]
struct LogWatch {
    item_id: i64,
    played_at: Option<String>,
}

async fn create(ctx: Ctx, Form(form): Form<LogWatch>) -> Result {
    let user = ctx.user().clone();
    let started_at = manual_started_at(form.played_at.as_deref(), &user.timezone)?;
    let item_id = ctx
        .blocking(move |conn| {
            let item = Item::find(conn, form.item_id)?.ok_or(AppError::NotFound)?;
            // Music is only ever recorded from the plugin, never by hand.
            if item.media_type == "track" {
                return Err(AppError::Unprocessable(
                    "Tracks can't be logged manually".into(),
                ));
            }
            Play::create(
                conn,
                &NewPlay {
                    user_id: user.id,
                    item_id: item.id,
                    source: "manual".into(),
                    started_at: Some(started_at),
                    ..NewPlay::default()
                },
            )?;
            Ok(item.id)
        })
        .await?;
    Ok(redirect(&format!("/items/{item_id}")))
}

async fn destroy(ctx: Ctx, headers: HeaderMap, Path(id): Path<i64>) -> Result {
    let user_id = ctx.user().id;
    ctx.blocking(move |conn| {
        let play = Play::find(conn, id)?
            .filter(|p| p.user_id == user_id)
            .ok_or(AppError::NotFound)?;
        Play::delete(conn, play.id)?;
        Ok(())
    })
    .await?;
    let back = headers
        .get(header::REFERER)
        .and_then(|r| r.to_str().ok())
        .and_then(|r| url::Url::parse(r).ok())
        .map_or_else(
            || "/history".to_string(),
            |u| match u.query() {
                Some(q) => format!("{}?{q}", u.path()),
                None => u.path().to_string(),
            },
        );
    Ok(redirect(&back))
}
