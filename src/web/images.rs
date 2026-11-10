//! `/images/<token>.jpg`: cover art through a local disk cache.
//!
//! The token encodes the art's owner, so every item sharing a cover resolves
//! to one file. A hit is served from disk; a miss tries each upstream in turn
//! (stored poster, source-derived art, the item's own Jellyfin artwork),
//! stores the first that answers, heals the item's poster path to it, and
//! serves it.

use axum::Router;
use axum::extract::Path;
use axum::http::header;
use axum::response::{IntoResponse, Redirect};
use axum::routing::get;
use rusqlite::Connection;
use serde_json::Value;

use super::media::{decode_image_token, jellyfin_source_url, remote_poster_url};
use super::{AppError, Ctx, Result, State};
use crate::config::Config;
use crate::models::item::{Attrs, Item};
use crate::services::fanart::Fanart;
use crate::services::image_cache;

const CACHE: &str = "public, max-age=31536000, immutable";

pub fn routes() -> Router<State> {
    Router::new().route("/images/{name}", get(show))
}

fn valid_name(name: &str) -> Option<&str> {
    let token = name.strip_suffix(".jpg")?;
    (!token.is_empty()
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'))
    .then_some(token)
}

async fn show(ctx: Ctx, Path(name): Path<String>) -> Result {
    let Some(token) = valid_name(&name) else {
        return Err(AppError::NotFound);
    };
    let path = ctx.state.config.image_storage_dir().join(&name);
    if let Ok(bytes) = tokio::fs::read(&path).await {
        return Ok(jpeg(bytes));
    }
    let Some((media_type, external_id, size)) = decode_image_token(token) else {
        return Err(AppError::NotFound);
    };
    let config = ctx.state.config.clone();
    let fetched = ctx
        .blocking(move |conn| Ok(fetch(conn, &config, &media_type, &external_id, &size)?))
        .await?;
    let Some(bytes) = fetched else {
        return Ok((
            [(header::CACHE_CONTROL, "public, max-age=60")],
            Redirect::to("/poster-placeholder.svg"),
        )
            .into_response());
    };
    store(&ctx.state.config, &name, &bytes);
    Ok(jpeg(bytes))
}

fn jpeg(bytes: Vec<u8>) -> axum::response::Response {
    (
        [
            (header::CONTENT_TYPE, "image/jpeg"),
            (header::CACHE_CONTROL, CACHE),
        ],
        bytes,
    )
        .into_response()
}

fn store(config: &Config, name: &str, bytes: &[u8]) {
    let dir = config.image_storage_dir();
    let path = dir.join(name);
    let tmp = dir.join(format!(
        "{name}.{}.tmp",
        hex::encode(rand::random::<[u8; 4]>())
    ));
    let result = std::fs::create_dir_all(&dir)
        .and_then(|()| std::fs::write(&tmp, bytes))
        .and_then(|()| std::fs::rename(&tmp, &path));
    if let Err(error) = result {
        tracing::warn!("[images] couldn't store {name}: {error}");
    }
}

/// Fetches the first upstream that answers; heals the item's poster path.
fn fetch(
    conn: &Connection,
    config: &Config,
    media_type: &str,
    external_id: &str,
    size: &str,
) -> anyhow::Result<Option<Vec<u8>>> {
    let base = jellyfin_source_url(conn)?;
    let all_hosts = {
        let mut stmt = conn.prepare("SELECT url FROM sources")?;
        let urls: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        image_cache::source_hosts(&urls)
    };

    if media_type == "season" {
        let Some(url) = season_poster_remote(conn, external_id, size)? else {
            return Ok(None);
        };
        return Ok(image_cache::fetch(&url, &all_hosts));
    }

    let Some(item) = Item::find_by_key(conn, media_type, external_id)? else {
        tracing::info!(
            "[images] miss {media_type}:{external_id} — unknown item, serving placeholder"
        );
        return Ok(None);
    };
    let stored = remote_poster_url(item.poster_path.as_deref(), size, base.as_deref());
    let candidates: [&dyn Fn() -> Option<String>; 3] = [
        &|| stored.clone(),
        &|| derived_poster_url(config, &item),
        &|| {
            let id = item.jellyfin_id.as_deref().filter(|i| !i.is_empty())?;
            base.as_ref()
                .map(|b| format!("{b}/Items/{id}/Images/Primary"))
        },
    ];
    for candidate in candidates {
        let Some(url) = candidate() else { continue };
        tracing::info!("[images] miss {media_type}:{external_id}, downloading {url}");
        if let Some(bytes) = image_cache::fetch(&url, &all_hosts) {
            if item.poster_path.as_deref().is_none_or(str::is_empty)
                || Some(&url) != stored.as_ref()
            {
                Item::update(conn, item.id, &Attrs::new().text("poster_path", Some(url)))?;
            }
            return Ok(Some(bytes));
        }
    }
    tracing::info!("[images] miss {media_type}:{external_id} — no working cover source");
    Ok(None)
}

fn derived_poster_url(config: &Config, item: &Item) -> Option<String> {
    match item.media_type.as_str() {
        "artist" => Fanart::new(config).artist_image(item.external_id.strip_prefix("mbid:artist:")),
        "album" => item
            .external_id
            .strip_prefix("mbid:rg:")
            .map(|mbid| format!("https://coverartarchive.org/release-group/{mbid}/front-250")),
        _ => None,
    }
}

/// A TV season's poster from its series' stored seasons. The external id is
/// "<series external id>:<season number>".
fn season_poster_remote(
    conn: &Connection,
    external_id: &str,
    size: &str,
) -> anyhow::Result<Option<String>> {
    let Some((series_id, number)) = external_id.rsplit_once(':') else {
        return Ok(None);
    };
    let Some(series) = Item::find_by_key(conn, "series", series_id)? else {
        return Ok(None);
    };
    let path = series
        .metadata
        .get("seasons")
        .and_then(Value::as_array)
        .and_then(|seasons| {
            seasons.iter().find(|s| {
                s["season_number"]
                    .as_i64()
                    .map(|n| n.to_string())
                    .as_deref()
                    == Some(number)
            })
        })
        .and_then(|s| s["poster_path"].as_str())
        .filter(|p| !p.is_empty())
        .map(String::from);
    Ok(path.map(|p| format!("https://image.tmdb.org/t/p/{size}{p}")))
}
