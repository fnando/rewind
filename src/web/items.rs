//! Item pages (movie, episode, series, track, music video, album, artist),
//! search, and rating, reviewing and logging from them.

use std::collections::HashMap;
use std::fmt::Write as _;

use askama::Template;
use axum::Router;
use axum::extract::{Form, Path, Query};
use axum::http::{HeaderMap, header};
use axum::routing::{get, post};
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::Value;

use super::cards::{self, AlbumCard};
use super::helpers::{self, h};
use super::{AppError, Ctx, Page, Result, State, media, redirect, render};
use crate::models::play::{NewPlay, Play};
use crate::models::{Item, User, UserItem};
use crate::services::tmdb::{SearchResult, Tmdb};
use crate::time;

pub fn routes() -> Router<State> {
    Router::new()
        .route("/search", get(search))
        .route("/items/import", post(import))
        .route("/items/{id}", get(show))
        .route("/items/{id}/rating", post(rate))
        .route("/items/{id}/review", post(review))
        .route("/items/{id}/log-episode", post(log_episode))
}

// --- View models ---

pub struct PlayRow {
    pub id: i64,
    pub iso: String,
    pub date: String,
    pub time: String,
    pub via: String,
}

/// The plays of one item, for the chips and the list.
pub struct Plays {
    pub heading: &'static str,
    pub empty: &'static str,
    pub remove_label: &'static str,
    pub verb: &'static str,
    pub rows: Vec<PlayRow>,
    pub count: usize,
    pub count_label: String,
    pub last: Option<String>,
}

impl Plays {
    fn new(plays: &[Play], zone: &str, kind: &str) -> Self {
        let (heading, empty, remove_label, verb) = match kind {
            "track" => (
                "Your listens",
                "No listens logged yet.",
                "Remove this listen",
                "Played",
            ),
            "music_video" => (
                "Your plays",
                "No plays logged yet.",
                "Remove this play",
                "Watched",
            ),
            _ => (
                "Your watches",
                "No watches logged yet.",
                "Remove this watch",
                "Watched",
            ),
        };
        let rows = plays
            .iter()
            .map(|play| PlayRow {
                id: play.id,
                iso: helpers::iso(&play.started_at),
                date: helpers::format_datetime(&play.started_at, zone, "%a, %b %-d, %Y"),
                time: helpers::format_time(&play.started_at, zone),
                via: if play.source == "manual" {
                    "Logged manually".into()
                } else {
                    format!("via {}", cards::source_label(&play.source))
                },
            })
            .collect();
        Self {
            heading,
            empty,
            remove_label,
            verb,
            rows,
            count: plays.len(),
            count_label: helpers::pluralize(
                i64::try_from(plays.len()).unwrap_or(0),
                "time",
                None,
                true,
            ),
            last: plays
                .first()
                .map(|p| helpers::format_datetime(&p.started_at, zone, "%b %-d, %Y")),
        }
    }
}

pub struct Review {
    pub kind_label: &'static str,
    pub editing: bool,
    pub text: String,
    pub written_html: String,
    pub rating: Option<i64>,
}

impl Review {
    fn new(item: &Item, user_item: Option<&UserItem>, editing: bool, zone: &str) -> Self {
        let text = user_item.and_then(|u| u.review.clone()).unwrap_or_default();
        let date = |value: &str| {
            format!(
                r#"<time datetime="{}">{}</time>"#,
                helpers::iso(value),
                helpers::format_datetime(value, zone, "%b %-d, %Y")
            )
        };
        let written_html = match user_item.and_then(|u| u.review_created_at.as_deref()) {
            Some(created) => {
                let mut out = date(created);
                let updated = user_item.and_then(|u| u.review_updated_at.as_deref());
                if let (Some(updated), Some(c)) =
                    (updated.and_then(time::parse), time::parse(created))
                    && updated.duration_since(c).as_secs() > 60
                {
                    let _ = write!(out, " · edited {}", date(&time::format(updated)));
                }
                out
            }
            None => String::new(),
        };
        Self {
            kind_label: match item.media_type.as_str() {
                "movie" => "movie",
                "episode" => "episode",
                "series" => "series",
                "track" => "track",
                "album" => "album",
                "artist" => "artist",
                "music_video" => "music video",
                _ => "item",
            },
            editing: editing || text.is_empty(),
            text,
            written_html,
            rating: user_item.and_then(|u| u.rating),
        }
    }
}

pub struct Actor {
    pub id: String,
    pub photo: Option<String>,
    pub name: String,
    pub role: Option<String>,
}

fn credits_names(item: &Item, job: &str) -> String {
    item.credits()
        .and_then(|c| c.get("crew"))
        .and_then(Value::as_array)
        .map(|crew| {
            crew.iter()
                .filter(|c| c["job"] == job)
                .filter_map(|c| c["name"].as_str())
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default()
}

fn top_cast(item: &Item) -> Vec<Actor> {
    item.credits()
        .and_then(|c| c.get("cast"))
        .and_then(Value::as_array)
        .map(|cast| {
            cast.iter()
                .take(8)
                .map(|a| Actor {
                    id: a["id"].to_string(),
                    photo: a["profile_path"].as_str().map(String::from),
                    name: a["name"].as_str().unwrap_or_default().into(),
                    role: a["character"]
                        .as_str()
                        .filter(|r| !r.is_empty())
                        .map(String::from),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn year(value: Option<&str>) -> String {
    value.unwrap_or_default().chars().take(4).collect()
}

// --- Pages ---

#[derive(Template)]
#[template(path = "items/movie.html")]
struct MoviePage {
    page: Page,
    item: Item,
    poster: String,
    meta: String,
    credit: String,
    rating_html: String,
    now_local: String,
    plays: Plays,
    review: Review,
    cast: Vec<Actor>,
}

#[derive(Template)]
#[template(path = "items/episode.html")]
struct EpisodePage {
    page: Page,
    item: Item,
    show: Option<Item>,
    poster: String,
    meta: String,
    rating_html: String,
    now_local: String,
    plays: Plays,
    review: Review,
}

#[derive(Template)]
#[template(path = "items/media.html")]
struct MediaPage {
    page: Page,
    item: Item,
    eyebrow: &'static str,
    poster: String,
    poster_class: &'static str,
    meta_html: String,
    rating_html: String,
    plays: Plays,
    review: Review,
}

pub struct EpisodeSlot {
    pub number: i64,
    pub name: String,
    pub still: String,
    pub latest: Option<LatestWatch>,
    pub watches: usize,
    pub rating_html: String,
}

pub struct LatestWatch {
    pub play_id: i64,
    pub item_id: i64,
    pub status: String,
}

#[derive(Template)]
#[template(path = "items/series.html")]
struct SeriesPage {
    page: Page,
    item: Item,
    poster: String,
    meta: String,
    credit: String,
    total_episodes: i64,
    watched_episodes: i64,
    percent: i64,
    seasons: Vec<i64>,
    current_season: i64,
    episodes: Vec<EpisodeSlot>,
    cast: Vec<Actor>,
}

pub struct WatchedEpisode {
    pub item_id: i64,
    pub title: String,
    pub poster: String,
    pub date: Option<String>,
    pub status: String,
    pub watches: usize,
    pub latest_play_id: i64,
    pub rating_html: String,
}

#[derive(Template)]
#[template(path = "items/series_generic.html")]
struct GenericSeriesPage {
    page: Page,
    item: Item,
    poster: String,
    watched_label: String,
    episodes: Vec<WatchedEpisode>,
}

pub struct TrackRow {
    pub id: i64,
    pub number: i64,
    pub title: String,
    pub plays: i64,
    pub bar: String,
    pub length: Option<(String, String)>,
}

#[derive(Template)]
#[template(path = "items/album.html")]
struct AlbumPage {
    page: Page,
    item: Item,
    artist: Option<Item>,
    poster: String,
    meta: String,
    total_plays: i64,
    total_plays_label: String,
    complete_listens: i64,
    complete_listens_label: String,
    last_played: Option<String>,
    rating_html: String,
    tracks: Vec<TrackRow>,
    tracks_label: String,
    max_track_plays: i64,
    total_length: String,
    review: Review,
}

pub struct VideoCard {
    pub id: i64,
    pub title: String,
    pub cover_url: String,
    pub has_cover: bool,
    pub year: String,
}

#[derive(Template)]
#[template(path = "items/artist.html")]
struct ArtistPage {
    page: Page,
    item: Item,
    poster: String,
    albums_label: String,
    rating_html: String,
    sections: Vec<(&'static str, Vec<AlbumCard>)>,
    videos: Vec<VideoCard>,
    review: Review,
}

#[derive(Template)]
#[template(path = "items/search.html")]
struct SearchPage {
    page: Page,
    query: String,
    error: Option<String>,
    configured: bool,
    results: Vec<SearchResult>,
}

// --- Handlers ---

#[derive(Deserialize, Default)]
struct SearchQuery {
    q: Option<String>,
}

async fn search(ctx: Ctx, Query(query): Query<SearchQuery>) -> Result {
    let query = query.q.unwrap_or_default().trim().to_string();
    let tmdb = Tmdb::new(&ctx.state.config);
    let configured = tmdb.configured();
    let (results, error) = if query.is_empty() || !configured {
        (Vec::new(), None)
    } else {
        let q = query.clone();
        match tokio::task::spawn_blocking(move || tmdb.search_multi(&q))
            .await
            .map_err(anyhow::Error::from)?
        {
            Ok(results) => (results, None),
            Err(error) => (Vec::new(), Some(error.to_string())),
        }
    };
    let mut page = ctx.page("Search");
    page.search.clone_from(&query);
    render(&SearchPage {
        page,
        query,
        error,
        configured,
        results,
    })
}

#[derive(Deserialize)]
struct Import {
    media_type: String,
    tmdb_id: i64,
}

async fn import(ctx: Ctx, Form(form): Form<Import>) -> Result {
    let tmdb = Tmdb::new(&ctx.state.config);
    let id = ctx
        .blocking(move |conn| {
            let item = match form.media_type.as_str() {
                "movie" => tmdb.movie(conn, form.tmdb_id)?,
                "series" => tmdb.tv_item(conn, form.tmdb_id)?,
                _ => return Err(AppError::BadRequest("Unsupported media_type".into())),
            };
            Ok(item.id)
        })
        .await?;
    Ok(redirect(&format!("/items/{id}")))
}

/// Back where the form was, or the item page.
fn back(headers: &HeaderMap, fallback: &str) -> String {
    headers
        .get(header::REFERER)
        .and_then(|r| r.to_str().ok())
        .and_then(|r| url::Url::parse(r).ok())
        .map_or_else(
            || fallback.to_string(),
            |u| match u.query() {
                Some(q) => format!("{}?{q}", u.path()),
                None => u.path().to_string(),
            },
        )
}

#[derive(Deserialize)]
struct Rating {
    #[serde(default)]
    rating: String,
}

async fn rate(
    ctx: Ctx,
    headers: HeaderMap,
    Path(id): Path<i64>,
    Form(form): Form<Rating>,
) -> Result {
    let user_id = ctx.user().id;
    let rating = match form.rating.as_str() {
        "" | "clear" => None,
        "up" => Some(5),
        "down" => Some(1),
        other => other.parse::<i64>().ok().filter(|r| (1..=5).contains(r)),
    };
    ctx.blocking(move |conn| {
        let item = Item::find(conn, id)?.ok_or(AppError::NotFound)?;
        UserItem::set_rating(conn, user_id, &item.rating_key(), rating)?;
        Ok(())
    })
    .await?;
    Ok(redirect(&back(&headers, &format!("/items/{id}"))))
}

#[derive(Deserialize)]
struct ReviewForm {
    #[serde(default)]
    review: String,
}

async fn review(ctx: Ctx, Path(id): Path<i64>, Form(form): Form<ReviewForm>) -> Result {
    let user_id = ctx.user().id;
    ctx.blocking(move |conn| {
        let item = Item::find(conn, id)?.ok_or(AppError::NotFound)?;
        let existing = UserItem::find(conn, user_id, &item.rating_key())?;
        // Only an actual change moves the edit time.
        if existing.as_ref().and_then(|u| u.review.as_deref()) != Some(form.review.trim()) {
            UserItem::set_review(conn, user_id, &item.rating_key(), &form.review)?;
        }
        Ok(())
    })
    .await?;
    Ok(redirect(&format!("/items/{id}")))
}

#[derive(Deserialize)]
struct LogEpisode {
    season: Option<String>,
    episode: Option<String>,
    played_at: Option<String>,
}

async fn log_episode(ctx: Ctx, Path(id): Path<i64>, Form(form): Form<LogEpisode>) -> Result {
    let user = ctx.user().clone();
    let number = |v: Option<&str>| {
        v.and_then(|s| s.trim().parse::<i64>().ok())
            .filter(|n| *n > 0)
    };
    let (Some(season), Some(episode)) = (
        number(form.season.as_deref()),
        number(form.episode.as_deref()),
    ) else {
        return Err(AppError::BadRequest("Invalid season/episode".into()));
    };
    let started_at = super::history::manual_started_at(form.played_at.as_deref(), &user.timezone)?;
    let tmdb = Tmdb::new(&ctx.state.config);
    ctx.blocking(move |conn| {
        let show = Item::find(conn, id)?
            .filter(|i| i.media_type == "series")
            .ok_or(AppError::NotFound)?;
        let show_id = show.tmdb_id().ok_or(AppError::NotFound)?;
        let item = tmdb.episode(conn, show_id, season, episode)?;
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
        Ok(())
    })
    .await?;
    Ok(redirect(&format!("/items/{id}")))
}

#[derive(Deserialize, Default)]
struct ShowQuery {
    editing: Option<String>,
    season: Option<String>,
}

fn plays_of(conn: &Connection, user_id: i64, item_id: i64) -> anyhow::Result<Vec<Play>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {} FROM plays WHERE user_id = ? AND item_id = ? ORDER BY started_at DESC, id DESC",
        crate::models::play::COLUMNS
    ))?;
    let rows = stmt.query_map([user_id, item_id], Play::from_row)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn by_external_id(conn: &Connection, external_id: Option<&str>) -> anyhow::Result<Option<Item>> {
    match external_id {
        Some(id) => Item::first(conn, "WHERE external_id = ? ORDER BY id", [id]),
        None => Ok(None),
    }
}

/// What a page needs from the request, captured before the blocking work.
struct Viewer {
    user: User,
    page: Page,
    editing: bool,
    season: Option<i64>,
    tmdb: Tmdb,
}

impl Viewer {
    fn rating(&self, item: &Item, user_item: Option<&UserItem>, on_cover: bool) -> String {
        media::rating_input(
            item.id,
            user_item.and_then(|u| u.rating),
            &self.user.rating_style,
            &self.page.csrf_tag(),
            on_cover,
        )
    }

    fn now_local(&self) -> String {
        time::local(time::now(), &self.user.timezone)
            .strftime("%Y-%m-%dT%H:%M")
            .to_string()
    }
}

async fn show(ctx: Ctx, Path(id): Path<i64>, Query(query): Query<ShowQuery>) -> Result {
    let viewer = Viewer {
        user: ctx.user().clone(),
        page: ctx.page(""),
        editing: query.editing.as_deref() == Some("1"),
        season: query.season.as_deref().and_then(|s| s.parse().ok()),
        tmdb: Tmdb::new(&ctx.state.config),
    };
    let html = ctx
        .blocking(move |conn| render_item(conn, viewer, id))
        .await?;
    Ok(axum::response::IntoResponse::into_response(
        axum::response::Html(html),
    ))
}

fn render_item(
    conn: &Connection,
    mut viewer: Viewer,
    id: i64,
) -> std::result::Result<String, AppError> {
    let item = Item::find(conn, id)?.ok_or(AppError::NotFound)?;
    let user_item = UserItem::find(conn, viewer.user.id, &item.rating_key())?;
    let zone = viewer.user.timezone.clone();
    let review = Review::new(&item, user_item.as_ref(), viewer.editing, &zone);
    let rating_html = viewer.rating(&item, user_item.as_ref(), false);
    let poster = media::poster_url(&item);

    let html = match item.media_type.as_str() {
        "episode" => episode_page(conn, viewer, item, poster, rating_html, review)?.render(),
        "series" if item.meta_str("source") == Some("jellyfin") => {
            viewer.page.title.clone_from(&item.title);
            generic_series(conn, &viewer, item, poster)?.render()
        }
        "series" => {
            viewer.page.title.clone_from(&item.title);
            series(conn, &viewer, item, poster)?.render()
        }
        "track" | "music_video" => {
            viewer.page.title.clone_from(&item.title);
            let artist = by_external_id(conn, item.meta_str("artist_external_id"))?;
            let album = by_external_id(conn, item.meta_str("album_external_id"))?;
            let meta = music_meta(&item, artist.as_ref(), album.as_ref());
            let track = item.media_type == "track";
            MediaPage {
                page: viewer.page,
                eyebrow: if track { "Track" } else { "Music Video" },
                poster: if track {
                    album
                        .as_ref()
                        .map_or_else(|| poster.clone(), media::poster_url)
                } else {
                    poster
                },
                poster_class: if track {
                    "album-cover"
                } else {
                    "title-hero__poster title-hero__poster--video"
                },
                meta_html: meta,
                rating_html,
                plays: Plays::new(
                    &plays_of(conn, viewer.user.id, item.id)?,
                    &zone,
                    &item.media_type,
                ),
                review,
                item,
            }
            .render()
        }
        "album" => {
            viewer.page.title.clone_from(&item.title);
            album(conn, &viewer, item, poster, rating_html, review)?.render()
        }
        "artist" => {
            viewer.page.title.clone_from(&item.title);
            artist(conn, &viewer, item, poster, rating_html, review)?.render()
        }
        _ => movie_page(conn, viewer, item, poster, rating_html, review)?.render(),
    };
    Ok(html.map_err(anyhow::Error::from)?)
}

fn episode_page(
    conn: &Connection,
    mut viewer: Viewer,
    item: Item,
    poster: String,
    rating_html: String,
    review: Review,
) -> anyhow::Result<EpisodePage> {
    let (season, episode) = (
        item.season_number.unwrap_or(0),
        item.episode_number.unwrap_or(0),
    );
    viewer.page.title = format!(
        "{} S{season}E{episode}",
        item.meta_str("series_name").unwrap_or_default()
    );
    let show = Item::find_by_key(
        conn,
        "series",
        item.parent_external_id.as_deref().unwrap_or_default(),
    )?;
    let mut parts = vec![format!("S{season} · E{episode}")];
    if item.release_date.is_some() {
        parts.push(year(item.release_date.as_deref()));
    }
    parts.extend(helpers::format_runtime(item.runtime));
    Ok(EpisodePage {
        now_local: viewer.now_local(),
        plays: Plays::new(
            &plays_of(conn, viewer.user.id, item.id)?,
            &viewer.user.timezone,
            "episode",
        ),
        page: viewer.page,
        show,
        poster,
        meta: parts.join(" · "),
        rating_html,
        review,
        item,
    })
}

fn movie_page(
    conn: &Connection,
    mut viewer: Viewer,
    item: Item,
    poster: String,
    rating_html: String,
    review: Review,
) -> anyhow::Result<MoviePage> {
    viewer.page.title.clone_from(&item.title);
    let mut parts = Vec::new();
    if item.release_date.is_some() {
        parts.push(year(item.release_date.as_deref()));
    }
    parts.extend(helpers::format_runtime(item.runtime));
    let genres = item.genres();
    if !genres.is_empty() {
        parts.push(genres.join(", "));
    }
    Ok(MoviePage {
        now_local: viewer.now_local(),
        plays: Plays::new(
            &plays_of(conn, viewer.user.id, item.id)?,
            &viewer.user.timezone,
            "movie",
        ),
        page: viewer.page,
        meta: parts.join(" · "),
        credit: credits_names(&item, "Director"),
        cast: top_cast(&item),
        poster,
        rating_html,
        review,
        item,
    })
}

/// "Artist · Album (year) · 4m · Genres", with links to what's known.
fn music_meta(item: &Item, artist: Option<&Item>, album: Option<&Item>) -> String {
    let mut parts = Vec::new();
    match (artist, item.artist()) {
        (Some(a), name) => parts.push(format!(
            r#"<a href="/items/{}">{}</a>"#,
            a.id,
            h(name.unwrap_or(&a.title))
        )),
        (None, Some(name)) => parts.push(h(name)),
        (None, None) => {}
    }
    if item.media_type == "track" {
        match (album, item.album()) {
            (Some(a), name) => {
                let album_year = year(a.release_date.as_deref());
                let suffix = if album_year.is_empty() {
                    String::new()
                } else {
                    format!(" ({album_year})")
                };
                parts.push(format!(
                    r#"<a href="/items/{}">{}</a>{suffix}"#,
                    a.id,
                    h(name.unwrap_or(&a.title))
                ));
            }
            (None, Some(name)) => parts.push(h(name)),
            (None, None) => {}
        }
    }
    if let Some(runtime) = helpers::format_runtime(item.runtime) {
        parts.push(h(&runtime));
    }
    let genres = item.genres();
    if !genres.is_empty() {
        parts.push(h(&genres.join(", ")));
    }
    parts.join(" · ")
}

/// Episodes played under a series, newest play first.
fn episode_plays(
    conn: &Connection,
    user_id: i64,
    series: &Item,
    season: Option<i64>,
) -> anyhow::Result<Vec<(Play, Item)>> {
    match season {
        Some(season) => cards::plays_with_items(
            conn,
            "WHERE plays.user_id = ?1 AND items.media_type = 'episode' AND items.parent_external_id = ?2 \
             AND items.season_number = ?3 ORDER BY plays.started_at DESC, plays.id DESC",
            rusqlite::params![user_id, series.external_id, season],
        ),
        None => cards::plays_with_items(
            conn,
            "WHERE plays.user_id = ?1 AND items.media_type = 'episode' AND items.parent_external_id = ?2 \
             ORDER BY plays.started_at DESC, plays.id DESC",
            rusqlite::params![user_id, series.external_id],
        ),
    }
}

fn watched_status(play: &Play, zone: &str) -> String {
    format!(
        "Watched {} · {}",
        helpers::format_datetime(&play.started_at, zone, "%b %-d"),
        cards::source_label(&play.source)
    )
}

fn series(
    conn: &Connection,
    viewer: &Viewer,
    item: Item,
    poster: String,
) -> anyhow::Result<SeriesPage> {
    let mut seasons: Vec<(i64, i64)> = item
        .metadata
        .get("seasons")
        .and_then(Value::as_array)
        .map(|seasons| {
            seasons
                .iter()
                .map(|s| {
                    (
                        s["season_number"].as_i64().unwrap_or(0),
                        s["episode_count"].as_i64().unwrap_or(0),
                    )
                })
                .filter(|(n, _)| *n != 0)
                .collect()
        })
        .unwrap_or_default();
    if seasons.is_empty() {
        seasons.push((1, 10));
    }
    let current_season = viewer.season.unwrap_or(seasons[0].0);
    let episode_count = seasons
        .iter()
        .find(|(n, _)| *n == current_season)
        .unwrap_or(&seasons[0])
        .1;

    let episodes = episode_slots(conn, viewer, &item, current_season, episode_count)?;

    let watched_episodes: i64 = conn.query_row(
        "SELECT count(DISTINCT plays.item_id) FROM plays JOIN items ON items.id = plays.item_id \
         WHERE plays.user_id = ? AND items.media_type = 'episode' AND items.parent_external_id = ?",
        rusqlite::params![viewer.user.id, item.external_id],
        |row| row.get(0),
    )?;
    let total_episodes: i64 = seasons.iter().map(|(_, c)| c).sum();
    #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
    let percent = if total_episodes > 0 {
        (watched_episodes as f64 / total_episodes as f64 * 100.0).round() as i64
    } else {
        0
    };

    let mut meta = Vec::new();
    if item.release_date.is_some() {
        meta.push(year(item.release_date.as_deref()));
    }
    let genres = item.genres();
    if !genres.is_empty() {
        meta.push(genres.join(", "));
    }
    if let Some(n) = item.meta_i64("number_of_seasons").filter(|n| *n > 0) {
        meta.push(helpers::pluralize(n, "season", None, true));
    }
    Ok(SeriesPage {
        page: viewer.page.clone(),
        meta: meta.join(" · "),
        credit: credits_names(&item, "Creator"),
        cast: top_cast(&item),
        poster,
        total_episodes,
        watched_episodes,
        percent,
        seasons: seasons.iter().map(|(n, _)| *n).collect(),
        current_season,
        episodes,
        item,
    })
}

/// Each episode of the season, watched or not.
fn episode_slots(
    conn: &Connection,
    viewer: &Viewer,
    item: &Item,
    current_season: i64,
    episode_count: i64,
) -> anyhow::Result<Vec<EpisodeSlot>> {
    let zone = &viewer.user.timezone;
    let plays = episode_plays(conn, viewer.user.id, item, Some(current_season))?;
    let mut by_number: HashMap<i64, Vec<&(Play, Item)>> = HashMap::new();
    for pair in &plays {
        by_number
            .entry(pair.1.episode_number.unwrap_or(0))
            .or_default()
            .push(pair);
    }
    let names: HashMap<i64, Value> = match (viewer.tmdb.configured(), item.tmdb_id()) {
        (true, Some(show_id)) => viewer
            .tmdb
            .season(show_id, current_season)
            .ok()
            .and_then(|s| s["episodes"].as_array().cloned())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|e| Some((e["episode_number"].as_i64()?, e)))
            .collect(),
        _ => HashMap::new(),
    };

    let episodes = (1..=episode_count)
        .map(|n| {
            let plays = by_number.get(&n).cloned().unwrap_or_default();
            let tmdb = names.get(&n);
            let latest = plays.first().map(|(play, ep)| LatestWatch {
                play_id: play.id,
                item_id: ep.id,
                status: watched_status(play, zone),
            });
            let rating_html = plays.first().map_or_else(String::new, |(_, ep)| {
                let ui = UserItem::find(conn, viewer.user.id, &ep.rating_key())
                    .ok()
                    .flatten();
                viewer.rating(ep, ui.as_ref(), false)
            });
            EpisodeSlot {
                number: n,
                name: tmdb
                    .and_then(|e| e["name"].as_str())
                    .map_or_else(|| format!("Episode {n}"), String::from),
                still: media::still_url(tmdb.and_then(|e| e["still_path"].as_str()), "w300"),
                latest,
                watches: plays.len(),
                rating_html,
            }
        })
        .collect();
    Ok(episodes)
}

fn generic_series(
    conn: &Connection,
    viewer: &Viewer,
    item: Item,
    poster: String,
) -> anyhow::Result<GenericSeriesPage> {
    let zone = &viewer.user.timezone;
    let plays = episode_plays(conn, viewer.user.id, &item, None)?;
    let mut order: Vec<i64> = Vec::new();
    let mut grouped: HashMap<i64, Vec<&(Play, Item)>> = HashMap::new();
    for pair in &plays {
        if !grouped.contains_key(&pair.1.id) {
            order.push(pair.1.id);
        }
        grouped.entry(pair.1.id).or_default().push(pair);
    }
    let episodes = order
        .iter()
        .map(|id| {
            let plays = &grouped[id];
            let (latest, ep) = plays[0];
            let ui = UserItem::find(conn, viewer.user.id, &ep.rating_key())
                .ok()
                .flatten();
            WatchedEpisode {
                item_id: ep.id,
                title: ep.title.clone(),
                poster: media::poster_url(ep),
                date: ep.release_date.as_deref().map(helpers::format_date),
                status: watched_status(latest, zone),
                watches: plays.len(),
                latest_play_id: latest.id,
                rating_html: viewer.rating(ep, ui.as_ref(), false),
            }
        })
        .collect::<Vec<_>>();
    Ok(GenericSeriesPage {
        page: viewer.page.clone(),
        watched_label: helpers::pluralize(
            i64::try_from(episodes.len()).unwrap_or(0),
            "episode",
            None,
            true,
        ),
        poster,
        episodes,
        item,
    })
}

fn album(
    conn: &Connection,
    viewer: &Viewer,
    item: Item,
    poster: String,
    rating_html: String,
    review: Review,
) -> anyhow::Result<AlbumPage> {
    let artist = by_external_id(conn, item.parent_external_id.as_deref())?;
    let mut tracks = Item::list(
        conn,
        "WHERE media_type = 'track' AND parent_external_id = ?",
        [&item.external_id],
    )?;
    tracks.sort_by(|a, b| {
        (
            a.disc_number().unwrap_or(0),
            a.track_number().unwrap_or(0),
            &a.title,
        )
            .cmp(&(
                b.disc_number().unwrap_or(0),
                b.track_number().unwrap_or(0),
                &b.title,
            ))
    });
    let mut counts = HashMap::new();
    let mut last_played: Option<String> = None;
    for track in &tracks {
        let (count, last): (i64, Option<String>) = conn.query_row(
            "SELECT count(*), max(started_at) FROM plays WHERE user_id = ? AND item_id = ?",
            [viewer.user.id, track.id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        counts.insert(track.id, count);
        if last.as_ref() > last_played.as_ref() {
            last_played = last;
        }
    }
    let values: Vec<i64> = tracks.iter().map(|t| counts[&t.id]).collect();
    let total_plays: i64 = values.iter().sum();
    let max_track_plays = values.iter().copied().max().unwrap_or(0);
    // A lower bound on full listens: times every track has been heard.
    let complete_listens = values.iter().copied().min().unwrap_or(0);
    let total_length_ms: i64 = tracks.iter().filter_map(|t| t.meta_i64("length_ms")).sum();
    let total_length = helpers::album_length(Some(total_length_ms)).unwrap_or_default();

    let mut meta = Vec::new();
    let album_year = year(item.release_date.as_deref());
    if !album_year.is_empty() {
        meta.push(album_year);
    }
    let tracks_label = helpers::pluralize(
        i64::try_from(tracks.len()).unwrap_or(0),
        "track",
        None,
        true,
    );
    meta.push(tracks_label.clone());
    if !total_length.is_empty() {
        meta.push(total_length.clone());
    }
    let genres = item.genres();
    if !genres.is_empty() {
        meta.push(genres.join(", "));
    }
    let rows = tracks
        .iter()
        .enumerate()
        .map(|(index, track)| {
            let plays = counts[&track.id];
            #[allow(clippy::cast_precision_loss)]
            let bar = if max_track_plays > 0 {
                format!("{:.1}", plays as f64 * 100.0 / max_track_plays as f64)
            } else {
                String::new()
            };
            let length_ms = track.meta_i64("length_ms");
            TrackRow {
                id: track.id,
                number: track
                    .track_number()
                    .unwrap_or(i64::try_from(index).unwrap_or(0) + 1),
                title: track.title.clone(),
                plays,
                bar,
                length: helpers::track_length(length_ms).zip(helpers::track_length_iso(length_ms)),
            }
        })
        .collect();
    Ok(AlbumPage {
        page: viewer.page.clone(),
        artist,
        poster,
        meta: meta.join(" · "),
        total_plays,
        total_plays_label: helpers::pluralize(total_plays, "track play", None, true),
        complete_listens,
        complete_listens_label: helpers::pluralize(complete_listens, "time", None, true),
        last_played: last_played
            .map(|l| helpers::format_datetime(&l, &viewer.user.timezone, "%b %-d, %Y")),
        rating_html,
        tracks: rows,
        tracks_label,
        max_track_plays,
        total_length,
        review,
        item,
    })
}

/// Release-type sections in a fixed order, or one "Albums" list when no
/// album knows its type.
const RELEASE_SECTIONS: &[(&str, &str)] = &[
    ("album", "Albums"),
    ("ep", "EPs"),
    ("single", "Singles"),
    ("compilation", "Compilations"),
    ("other", "Other"),
];

fn release_bucket(kind: &str) -> &'static str {
    let kind = kind.to_lowercase();
    if kind.contains("compilation") {
        "compilation"
    } else if kind.contains("ep") {
        "ep"
    } else if kind.contains("single") {
        "single"
    } else if kind.contains("album") {
        "album"
    } else {
        "other"
    }
}

fn artist(
    conn: &Connection,
    viewer: &Viewer,
    item: Item,
    poster: String,
    rating_html: String,
    review: Review,
) -> anyhow::Result<ArtistPage> {
    // Newest first; undated albums last, then by title.
    let order = "ORDER BY release_date IS NULL, release_date DESC, title";
    let albums = Item::list(
        conn,
        &format!("WHERE media_type = 'album' AND parent_external_id = ? {order}"),
        [&item.external_id],
    )?;
    let videos = Item::list(
        conn,
        &format!("WHERE media_type = 'music_video' AND parent_external_id = ? {order}"),
        [&item.external_id],
    )?;
    let refs: Vec<&Item> = albums.iter().collect();
    let ratings = media::user_items_by_item(conn, viewer.user.id, &refs)?;
    let card = |album: &Item| {
        AlbumCard::new(
            album,
            h(&year(album.release_date.as_deref())),
            String::new(),
            None,
            viewer.rating(album, ratings.get(&album.id), true),
        )
    };
    let typed = albums.iter().any(|a| a.meta_str("release_type").is_some());
    let sections = if albums.is_empty() {
        Vec::new()
    } else if typed {
        RELEASE_SECTIONS
            .iter()
            .filter_map(|(key, heading)| {
                let list: Vec<AlbumCard> = albums
                    .iter()
                    .filter(|a| {
                        release_bucket(a.meta_str("release_type").unwrap_or_default()) == *key
                    })
                    .map(card)
                    .collect();
                (!list.is_empty()).then_some((*heading, list))
            })
            .collect()
    } else {
        vec![("Albums", albums.iter().map(card).collect())]
    };
    Ok(ArtistPage {
        page: viewer.page.clone(),
        albums_label: helpers::pluralize(
            i64::try_from(albums.len()).unwrap_or(0),
            "album",
            None,
            true,
        ),
        poster,
        rating_html,
        sections,
        videos: videos
            .iter()
            .map(|v| VideoCard {
                id: v.id,
                title: v.title.clone(),
                cover_url: media::poster_url(v),
                has_cover: media::has_poster(v),
                year: year(v.release_date.as_deref()),
            })
            .collect(),
        review,
        item,
    })
}
