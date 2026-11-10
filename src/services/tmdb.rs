//! TMDB: movie, series and episode metadata, cached as items for a week.

use anyhow::{Result, bail};
use jiff::ToSpan;
use rusqlite::Connection;
use serde_json::{Value, json};

use super::http;
use crate::config::Config;
use crate::models::item::{Attrs, Item};
use crate::time;

const CACHE_TTL_DAYS: i64 = 7;

#[derive(Debug, Clone)]
pub struct Tmdb {
    api_key: Option<String>,
    base_url: String,
}

/// A search hit, normalized to Rewind's media types.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchResult {
    pub media_type: String,
    pub tmdb_id: i64,
    pub title: String,
    pub overview: Option<String>,
    pub release_date: Option<String>,
    pub poster_path: Option<String>,
}

fn s(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .map(String::from)
}

impl Tmdb {
    #[must_use]
    pub fn new(config: &Config) -> Self {
        Self {
            api_key: config.tmdb_api_key.clone(),
            base_url: config.tmdb_url.clone(),
        }
    }

    #[must_use]
    pub fn configured(&self) -> bool {
        self.api_key.is_some()
    }

    fn get(&self, path: &str, params: &[(&str, &str)]) -> Result<Value> {
        let Some(key) = &self.api_key else {
            bail!("TMDB_API_KEY not configured");
        };
        let mut request = http::get(format!("{}{path}", self.base_url))
            .header("Authorization", format!("Bearer {key}"));
        for (k, v) in params {
            request = request.query(k, v);
        }
        let response = request
            .send()
            .map_err(|e| anyhow::anyhow!("TMDB request failed: {e}"))?;
        if !response.ok() {
            bail!("TMDB request failed: {}", response.status);
        }
        response.json()
    }

    pub fn search_multi(&self, query: &str) -> Result<Vec<SearchResult>> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let data = self.get("/search/multi", &[("query", query)])?;
        Ok(data
            .get("results")
            .and_then(Value::as_array)
            .map(|results| results.iter().filter_map(normalize_search_result).collect())
            .unwrap_or_default())
    }

    pub fn tv(&self, tmdb_id: i64) -> Result<Value> {
        self.get(
            &format!("/tv/{tmdb_id}"),
            &[("append_to_response", "credits")],
        )
    }

    pub fn season(&self, show_id: i64, season: i64) -> Result<Value> {
        self.get(&format!("/tv/{show_id}/season/{season}"), &[])
    }

    pub fn find_by_imdb(&self, imdb_id: &str) -> Result<Value> {
        self.get(
            &format!("/find/{imdb_id}"),
            &[("external_source", "imdb_id")],
        )
    }

    pub fn movie(&self, conn: &Connection, tmdb_id: i64) -> Result<Item> {
        let existing = Item::find_by_key(conn, "movie", &format!("tmdb:{tmdb_id}"))?;
        if let Some(item) = fresh(existing.as_ref()) {
            return Ok(item);
        }
        let data = self.get(
            &format!("/movie/{tmdb_id}"),
            &[("append_to_response", "credits")],
        )?;
        let attrs = Attrs::new()
            .text(
                "title",
                s(&data, "title").or_else(|| s(&data, "original_title")),
            )
            .text("overview", s(&data, "overview"))
            .text("release_date", s(&data, "release_date"))
            .text("poster_path", s(&data, "poster_path"))
            .int("runtime", data.get("runtime").and_then(Value::as_i64))
            .metadata(&json!({"genres": data.get("genres"), "credits": data.get("credits")}));
        store(
            conn,
            existing.as_ref(),
            "movie",
            &format!("tmdb:{}", id_of(&data, tmdb_id)),
            &attrs,
        )
    }

    pub fn tv_item(&self, conn: &Connection, tmdb_id: i64) -> Result<Item> {
        let existing = Item::find_by_key(conn, "series", &format!("tmdb:{tmdb_id}"))?;
        if let Some(item) = fresh(existing.as_ref()) {
            return Ok(item);
        }
        let data = self.tv(tmdb_id)?;
        let seasons: Vec<Value> = data
            .get("seasons")
            .and_then(Value::as_array)
            .map(|seasons| {
                seasons
                    .iter()
                    .map(|s| {
                        json!({
                            "season_number": s.get("season_number"),
                            "name": s.get("name"),
                            "episode_count": s.get("episode_count"),
                            "poster_path": s.get("poster_path"),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let attrs = Attrs::new()
            .text(
                "title",
                s(&data, "name").or_else(|| s(&data, "original_name")),
            )
            .text("overview", s(&data, "overview"))
            .text("release_date", s(&data, "first_air_date"))
            .text("poster_path", s(&data, "poster_path"))
            .int("runtime", first_run_time(&data))
            .metadata(&json!({
                "series_name": data.get("name"),
                "genres": data.get("genres"),
                "credits": data.get("credits"),
                "number_of_seasons": data.get("number_of_seasons"),
                "seasons": seasons,
            }));
        store(
            conn,
            existing.as_ref(),
            "series",
            &format!("tmdb:{}", id_of(&data, tmdb_id)),
            &attrs,
        )
    }

    pub fn episode(
        &self,
        conn: &Connection,
        show_id: i64,
        season: i64,
        episode: i64,
    ) -> Result<Item> {
        let existing = Item::first(
            conn,
            "WHERE media_type = 'episode' AND parent_external_id = ? \
             AND season_number = ? AND episode_number = ?",
            rusqlite::params![format!("tmdb:{show_id}"), season, episode],
        )?;
        if let Some(item) = fresh(existing.as_ref()) {
            return Ok(item);
        }
        let data = self.get(
            &format!("/tv/{show_id}/season/{season}/episode/{episode}"),
            &[("append_to_response", "credits")],
        )?;
        self.tv_item(conn, show_id)?;
        let show = self.tv(show_id)?;
        let credits = data
            .get("credits")
            .filter(|c| !c.is_null())
            .or_else(|| show.get("credits"));
        let attrs = Attrs::new()
            .text("parent_external_id", Some(format!("tmdb:{show_id}")))
            .int("season_number", Some(season))
            .int("episode_number", Some(episode))
            .text("title", s(&data, "name"))
            .text("overview", s(&data, "overview"))
            .text("release_date", s(&data, "air_date"))
            .text("poster_path", s(&data, "still_path"))
            .int(
                "runtime",
                data.get("runtime")
                    .and_then(Value::as_i64)
                    .or_else(|| first_run_time(&show)),
            )
            .metadata(&json!({
                "series_name": show.get("name"),
                "genres": show.get("genres"),
                "credits": credits,
            }));
        let external_id = match data.get("id").and_then(Value::as_i64) {
            Some(id) => format!("tmdb:{id}"),
            None => format!("tmdb:{show_id}:{season}:{episode}"),
        };
        store(conn, existing.as_ref(), "episode", &external_id, &attrs)
    }
}

fn id_of(data: &Value, fallback: i64) -> i64 {
    data.get("id").and_then(Value::as_i64).unwrap_or(fallback)
}

fn first_run_time(data: &Value) -> Option<i64> {
    data.get("episode_run_time")
        .and_then(Value::as_array)
        .and_then(|runs| runs.first())
        .and_then(Value::as_i64)
}

/// The cached item when it was fetched within the TTL.
fn fresh(existing: Option<&Item>) -> Option<Item> {
    let item = existing?;
    let fetched = time::parse(&item.fetched_at)?;
    let cutoff = time::now()
        .checked_sub((CACHE_TTL_DAYS * 24).hours())
        .ok()?;
    (fetched > cutoff).then(|| item.clone())
}

/// Writes fresh attributes onto the cached row (whatever its key), or creates
/// the item.
fn store(
    conn: &Connection,
    existing: Option<&Item>,
    media_type: &str,
    external_id: &str,
    attrs: &Attrs,
) -> Result<Item> {
    match existing {
        Some(item) => Item::upsert(conn, &item.media_type, &item.external_id, attrs),
        None => Item::upsert(conn, media_type, external_id, attrs),
    }
}

fn normalize_search_result(result: &Value) -> Option<SearchResult> {
    let (media_type, title_keys, date_key) = match result.get("media_type")?.as_str()? {
        "movie" => ("movie", ["title", "original_title"], "release_date"),
        "tv" => ("series", ["name", "original_name"], "first_air_date"),
        _ => return None,
    };
    Some(SearchResult {
        media_type: media_type.into(),
        tmdb_id: result.get("id")?.as_i64()?,
        title: s(result, title_keys[0]).or_else(|| s(result, title_keys[1]))?,
        overview: s(result, "overview"),
        release_date: s(result, date_key),
        poster_path: s(result, "poster_path"),
    })
}
