//! The cover cards on History: one per play, plus album groups that fold a
//! run of tracks off the same album into one expandable card.

use std::collections::HashMap;

use rusqlite::Connection;
use serde_json::Value;

use super::helpers::{self, h};
use super::media;
use crate::models::play::{COLUMNS as PLAY_COLUMNS, Play};
use crate::models::{Item, UserItem};

/// Everything the cards on a page need, loaded once for all of its plays.
pub struct Context {
    pub zone: String,
    pub rating_style: String,
    pub csrf_tag: String,
    pub shows: HashMap<String, Item>,
    pub music_parents: HashMap<String, Item>,
    pub ratings: HashMap<i64, UserItem>,
}

impl Context {
    pub fn load(
        conn: &Connection,
        user_id: i64,
        zone: &str,
        rating_style: &str,
        csrf_tag: &str,
        plays: &[(Play, Item)],
    ) -> anyhow::Result<Self> {
        let mut shows = HashMap::new();
        let mut music_parents = HashMap::new();
        for (_, item) in plays {
            match item.media_type.as_str() {
                "episode" => {
                    if let Some(parent) = &item.parent_external_id
                        && !shows.contains_key(parent)
                        && let Some(show) = Item::find_by_key(conn, "series", parent)?
                    {
                        shows.insert(parent.clone(), show);
                    }
                }
                "track" | "music_video" => {
                    for key in ["artist_external_id", "album_external_id"] {
                        if let Some(id) = item.meta_str(key)
                            && !music_parents.contains_key(id)
                            && let Some(parent) =
                                Item::first(conn, "WHERE external_id = ? ORDER BY id", [id])?
                        {
                            music_parents.insert(id.to_string(), parent);
                        }
                    }
                }
                _ => {}
            }
        }
        let mut rated: Vec<&Item> = plays.iter().map(|(_, item)| item).collect();
        rated.extend(music_parents.values().filter(|i| i.media_type == "album"));
        let ratings = media::user_items_by_item(conn, user_id, &rated)?;
        Ok(Self {
            zone: zone.into(),
            rating_style: rating_style.into(),
            csrf_tag: csrf_tag.into(),
            shows,
            music_parents,
            ratings,
        })
    }

    fn rating_input(&self, item: &Item) -> String {
        let rating = self.ratings.get(&item.id).and_then(|r| r.rating);
        media::rating_input(item.id, rating, &self.rating_style, &self.csrf_tag, true)
    }
}

/// Plays with their items, for a `WHERE …` tail over `plays` joined to
/// `items`.
pub fn plays_with_items<P: rusqlite::Params>(
    conn: &Connection,
    tail: &str,
    params: P,
) -> anyhow::Result<Vec<(Play, Item)>> {
    let sql = format!(
        "SELECT {PLAY_COLUMNS}, {} FROM plays JOIN items ON items.id = plays.item_id {tail}",
        crate::models::item::COLUMNS
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params, |row| {
        Ok((Play::from_row(row)?, Item::from_row_at(row, 20)?))
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub struct PlayCard {
    pub play_id: i64,
    pub kind: String,
    pub kind_label: String,
    pub title: String,
    pub item_id: i64,
    pub cover_url: String,
    pub has_cover: bool,
    pub detail_html: String,
    pub meta_html: String,
    pub rating_html: String,
    pub group_key: Option<String>,
}

fn kind_label(kind: &str) -> String {
    match kind {
        "movie" => "Movie".into(),
        "episode" => "Episode".into(),
        "track" => "Track".into(),
        "music_video" => "Music Video".into(),
        other => {
            let mut chars = other.chars();
            chars
                .next()
                .map(|c| c.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        }
    }
}

#[must_use]
pub fn source_label(source: &str) -> String {
    kind_label(source)
}

/// The art an episode card shows: its season's poster when the series has
/// one, else the series, else the episode itself.
#[must_use]
pub fn cover_owner(item: &Item, show: Option<&Item>) -> Option<(String, String)> {
    if item.media_type != "episode" {
        return media::item_owner(item);
    }
    if let Some(series) = show {
        let has_season_poster = series
            .metadata
            .get("seasons")
            .and_then(Value::as_array)
            .and_then(|seasons| {
                seasons
                    .iter()
                    .find(|s| s["season_number"].as_i64() == Some(item.season_number.unwrap_or(0)))
            })
            .and_then(|s| s["poster_path"].as_str())
            .is_some_and(|p| !p.is_empty());
        if has_season_poster {
            return Some((
                "season".into(),
                format!("{}:{}", series.external_id, item.season_number.unwrap_or(0)),
            ));
        }
        return media::item_owner(series);
    }
    media::item_owner(item)
}

/// "S1 · E2" (TMDB) or the air date (Jellyfin-native), before an episode's
/// series name.
#[must_use]
pub fn episode_prefix(item: &Item) -> Option<String> {
    if item.meta_str("source") == Some("jellyfin") {
        item.release_date.as_deref().map(helpers::format_date)
    } else {
        Some(format!(
            "S{} · E{}",
            item.season_number.unwrap_or(0),
            item.episode_number.unwrap_or(0)
        ))
    }
}

impl PlayCard {
    #[must_use]
    pub fn new(ctx: &Context, play: &Play, item: &Item, group_key: Option<String>) -> Self {
        let show = (item.media_type == "episode")
            .then(|| {
                item.parent_external_id
                    .as_ref()
                    .and_then(|p| ctx.shows.get(p))
            })
            .flatten();
        let owner = cover_owner(item, show);
        let parent = |key: &str| item.meta_str(key).and_then(|id| ctx.music_parents.get(id));
        let detail_html = match item.media_type.as_str() {
            "track" => {
                let mut parts = Vec::new();
                if let Some(artist) = item.artist() {
                    parts.push(media::item_link(parent("artist_external_id"), artist));
                }
                if let Some(album) = item.album() {
                    parts.push(media::item_link(parent("album_external_id"), album));
                }
                parts.join(" · ")
            }
            "music_video" => item
                .artist()
                .map(|artist| media::item_link(parent("artist_external_id"), artist))
                .unwrap_or_default(),
            "episode" => {
                let name = item
                    .meta_str("series_name")
                    .map(String::from)
                    .or_else(|| show.map(|s| s.title.clone()))
                    .unwrap_or_else(|| item.title.clone());
                let series = media::item_link(show, &name);
                match episode_prefix(item) {
                    Some(prefix) => format!("{} — {series}", h(&prefix)),
                    None => series,
                }
            }
            _ => h(item
                .release_date
                .as_deref()
                .unwrap_or_default()
                .get(..4)
                .unwrap_or_default()),
        };
        Self {
            play_id: play.id,
            kind: item.media_type.clone(),
            kind_label: kind_label(&item.media_type),
            title: item.title.clone(),
            item_id: item.id,
            cover_url: media::poster_url_for(owner.as_ref(), "w500"),
            has_cover: owner.is_some(),
            detail_html,
            meta_html: format!(
                r#"<time datetime="{}">{}</time> · {}"#,
                helpers::iso(&play.started_at),
                helpers::format_time(&play.started_at, &ctx.zone),
                h(&source_label(&play.source))
            ),
            rating_html: ctx.rating_input(item),
            group_key,
        }
    }
}

pub struct AlbumCard {
    pub album_id: i64,
    pub title: String,
    pub cover_url: String,
    pub has_cover: bool,
    pub detail_html: String,
    pub meta_html: String,
    pub group_key: Option<String>,
    pub rating_html: String,
}

impl AlbumCard {
    /// A generic album card (history group header, artist discography).
    #[must_use]
    pub fn new(
        album: &Item,
        detail_html: String,
        meta_html: String,
        group_key: Option<String>,
        rating_html: String,
    ) -> Self {
        Self {
            album_id: album.id,
            title: album.title.clone(),
            cover_url: media::poster_url(album),
            has_cover: media::has_poster(album),
            detail_html,
            meta_html,
            group_key,
            rating_html,
        }
    }
}

/// One history entry: a single play, or a run of tracks off one album.
pub enum Entry {
    Single(PlayCard),
    Album {
        album: AlbumCard,
        tracks: Vec<PlayCard>,
    },
}

/// Folds an ordered day of plays into entries, collapsing consecutive tracks
/// from the same album into a group (a lone track stays single).
#[must_use]
pub fn entries(ctx: &Context, plays: &[(Play, Item)]) -> Vec<Entry> {
    let mut runs: Vec<Vec<&(Play, Item)>> = Vec::new();
    for pair in plays {
        let album = (pair.1.media_type == "track")
            .then(|| pair.1.meta_str("album_external_id"))
            .flatten();
        let same = album.is_some()
            && runs.last().is_some_and(|run| {
                run[0].1.media_type == "track" && run[0].1.meta_str("album_external_id") == album
            });
        if same {
            runs.last_mut().expect("run").push(pair);
        } else {
            runs.push(vec![pair]);
        }
    }
    runs.into_iter()
        .map(|run| {
            if run.len() == 1 {
                let (play, item) = run[0];
                return Entry::Single(PlayCard::new(ctx, play, item, None));
            }
            album_group(ctx, &run)
        })
        .collect()
}

fn album_group(ctx: &Context, run: &[&(Play, Item)]) -> Entry {
    let (first_play, track) = run[0];
    let key = format!("group-{}", first_play.id);
    let artist_item = track
        .meta_str("artist_external_id")
        .and_then(|id| ctx.music_parents.get(id));
    let album_item = track
        .meta_str("album_external_id")
        .and_then(|id| ctx.music_parents.get(id));
    let album = album_item.unwrap_or(track);

    let first = run
        .iter()
        .map(|(p, _)| p.started_at.as_str())
        .min()
        .unwrap_or_default();
    let last = run
        .iter()
        .map(|(p, _)| p.started_at.as_str())
        .max()
        .unwrap_or_default();
    let (from, to) = (
        helpers::format_time(first, &ctx.zone),
        helpers::format_time(last, &ctx.zone),
    );
    let time_label = if from == to {
        from
    } else {
        format!("{from} – {to}")
    };
    let mut detail = String::new();
    if let Some(artist) = track.artist() {
        detail.push_str(&media::item_link(artist_item, artist));
        detail.push_str(" · ");
    }
    detail.push_str(&helpers::pluralize(
        i64::try_from(run.len()).unwrap_or(0),
        "track",
        None,
        true,
    ));
    let rating = album_item
        .and_then(|a| ctx.ratings.get(&a.id))
        .and_then(|r| r.rating);
    Entry::Album {
        album: AlbumCard::new(
            album,
            detail,
            format!("{time_label} · {}", h(&source_label(&first_play.source))),
            Some(key.clone()),
            media::rating_input(album.id, rating, &ctx.rating_style, &ctx.csrf_tag, true),
        ),
        tracks: run
            .iter()
            .map(|(play, item)| PlayCard::new(ctx, play, item, Some(key.clone())))
            .collect(),
    }
}
