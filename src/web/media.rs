//! Cover art URLs, links to items and the rating widgets, shared by the
//! history, item and stats pages.

use std::fmt::Write as _;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rusqlite::Connection;

use super::helpers::h;
use crate::models::{Item, UserItem};

/// The `(media_type, external_id)` that owns an item's cover: the album for a
/// track, else the item itself.
#[must_use]
pub fn poster_owner(
    media_type: &str,
    external_id: &str,
    album_external_id: Option<&str>,
) -> Option<(String, String)> {
    if media_type == "track"
        && let Some(album) = album_external_id.filter(|a| !a.is_empty())
    {
        return Some(("album".into(), album.into()));
    }
    (!external_id.is_empty()).then(|| (media_type.to_string(), external_id.to_string()))
}

#[must_use]
pub fn item_owner(item: &Item) -> Option<(String, String)> {
    poster_owner(
        &item.media_type,
        &item.external_id,
        item.meta_str("album_external_id"),
    )
}

/// A cover URL through the local image cache, keyed by the art's owner so
/// everything sharing a cover resolves to one cached file.
#[must_use]
pub fn poster_url_for(owner: Option<&(String, String)>, size: &str) -> String {
    match owner {
        Some((media_type, external_id)) => {
            let token = URL_SAFE_NO_PAD.encode(format!("{media_type}:{external_id}:{size}"));
            format!("/images/{token}.jpg")
        }
        None => "/poster-placeholder.svg".into(),
    }
}

#[must_use]
pub fn poster_url(item: &Item) -> String {
    poster_url_for(item_owner(item).as_ref(), "w500")
}

#[must_use]
pub fn has_poster(item: &Item) -> bool {
    item_owner(item).is_some()
}

/// Decodes an image token back into `(media_type, external_id, size)`.
#[must_use]
pub fn decode_image_token(token: &str) -> Option<(String, String, String)> {
    let decoded =
        String::from_utf8(URL_SAFE_NO_PAD.decode(token.trim_end_matches('=')).ok()?).ok()?;
    let parts: Vec<&str> = decoded.split(':').collect();
    if parts.len() < 3 {
        return None;
    }
    Some((
        parts[0].to_string(),
        parts[1..parts.len() - 1].join(":"),
        parts[parts.len() - 1].to_string(),
    ))
}

/// The URL of a connected Jellyfin server (enabled first), for re-hosting
/// stored Jellyfin image paths.
pub fn jellyfin_source_url(conn: &Connection) -> rusqlite::Result<Option<String>> {
    let url: Option<String> = conn
        .query_row(
            "SELECT url FROM sources WHERE type = 'jellyfin' ORDER BY enabled DESC, id LIMIT 1",
            [],
            |row| row.get(0),
        )
        .ok();
    Ok(url.map(|u| u.trim_end_matches('/').to_string()))
}

/// The "/Items/…/Images/…" part of a Jellyfin image reference.
#[must_use]
pub fn jellyfin_image_path(path: &str) -> Option<&str> {
    let start = path.find("/Items/")?;
    path.contains("/Images/").then(|| &path[start..])
}

/// The upstream URL for a stored poster path.
#[must_use]
pub fn remote_poster_url(
    poster_path: Option<&str>,
    size: &str,
    jellyfin_base: Option<&str>,
) -> Option<String> {
    let path = poster_path.filter(|p| !p.is_empty())?;
    if let Some(jf) = jellyfin_image_path(path) {
        return jellyfin_base.map(|base| format!("{base}{jf}"));
    }
    if path.starts_with("http://") || path.starts_with("https://") {
        return Some(path.to_string());
    }
    Some(format!("https://image.tmdb.org/t/p/{size}{path}"))
}

/// An episode still (TMDB path) or the placeholder.
#[must_use]
pub fn still_url(path: Option<&str>, size: &str) -> String {
    match path.filter(|p| !p.is_empty()) {
        None => "/still-placeholder.svg".into(),
        Some(p) if p.starts_with("http://") || p.starts_with("https://") => p.to_string(),
        Some(p) => format!("https://image.tmdb.org/t/p/{size}{p}"),
    }
}

/// A link to an item's page that reads like body text, or plain text when
/// the item isn't known.
#[must_use]
pub fn item_link(item: Option<&Item>, text: &str) -> String {
    match item {
        Some(item) => format!(
            r#"<a class="content-link" href="/items/{}">{}</a>"#,
            item.id,
            h(text)
        ),
        None => h(text),
    }
}

const STAR_PATH: &str = r#"<path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"/></svg>"#;
const THUMB_UP_SVG: &str = r#"<svg viewBox="0 0 24 24" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 10v10H4V10zM7 10l4-7a2 2 0 0 1 2 2v4h5.5a2 2 0 0 1 2 2.3l-1.3 7a2 2 0 0 1-2 1.7H7"/></svg>"#;
const THUMB_DOWN_SVG: &str = r#"<svg viewBox="0 0 24 24" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 14V4H4v10zM7 14l4 7a2 2 0 0 0 2-2v-4h5.5a2 2 0 0 0 2-2.3l-1.3-7a2 2 0 0 0-2-1.7H7"/></svg>"#;

fn star_svg(class: &str) -> String {
    format!(
        r#"<svg {class}viewBox="0 0 24 24" stroke-width="1.8" stroke-linejoin="round" aria-hidden="true">{STAR_PATH}"#
    )
}

/// The rate form for an item (stars or thumbs, per the user's style).
#[must_use]
pub fn rating_input(
    item_id: i64,
    rating: Option<i64>,
    style: &str,
    csrf_tag: &str,
    on_cover: bool,
) -> String {
    let action = format!("/items/{item_id}/rating");
    let cover = if on_cover { " on-cover" } else { "" };
    if style == "thumbs" {
        let up = rating.is_some_and(|r| r >= 3);
        let down = rating.is_some_and(|r| r < 3);
        return format!(
            "<form class=\"thumbs{cover}\" method=\"post\" action=\"{action}\" aria-label=\"Rate\">\n  {csrf_tag}\n  \
             <button name=\"rating\" value=\"up\" aria-label=\"Thumbs up\" aria-pressed=\"{up}\">{THUMB_UP_SVG}</button>\n  \
             <button name=\"rating\" value=\"down\" aria-label=\"Thumbs down\" aria-pressed=\"{down}\">{THUMB_DOWN_SVG}</button>\n</form>\n"
        );
    }
    let current = rating.unwrap_or(0);
    let mut buttons = String::new();
    for value in 1..=5 {
        let class = if value <= current {
            r#" class="is-on""#
        } else {
            ""
        };
        let pressed = if current == value {
            r#" aria-pressed="true""#
        } else {
            ""
        };
        let plural = if value == 1 { "" } else { "s" };
        let _ = write!(
            buttons,
            r#"<button{class} name="rating" value="{value}" aria-label="{value} star{plural}"{pressed}>{}</button>"#,
            star_svg("")
        );
    }
    format!(
        "<form class=\"stars{cover}\" method=\"post\" action=\"{action}\" aria-label=\"Rate\">\n  {csrf_tag}\n  {buttons}\n</form>\n"
    )
}

/// A compact rating (★★★ or a thumb), or "".
#[must_use]
pub fn rating_display(rating: Option<i64>, style: &str) -> String {
    let Some(rating) = rating else {
        return String::new();
    };
    if style == "thumbs" {
        let (svg, class, label) = if rating >= 3 {
            (THUMB_UP_SVG, "is-on", "Thumbs up")
        } else {
            (THUMB_DOWN_SVG, "is-off", "Thumbs down")
        };
        return format!(
            r#"<span class="rating-readout__thumb {class}" aria-label="{label}">{svg}</span>"#
        );
    }
    let filled = usize::try_from(rating.clamp(0, 5)).unwrap_or(0);
    format!(
        r#"{}<span class="stars__empty">{}</span>"#,
        "★".repeat(filled),
        "★".repeat(5 - filled)
    )
}

/// "Your rating" with the stars or thumb, or "".
#[must_use]
pub fn rating_readout(rating: Option<i64>, style: &str) -> String {
    let Some(rating) = rating else {
        return String::new();
    };
    if style == "thumbs" {
        let up = rating >= 3;
        let svg = if up { THUMB_UP_SVG } else { THUMB_DOWN_SVG };
        let class = if up { "is-up" } else { "is-down" };
        return format!(
            "<div class=\"rating-readout\">\n  <span>Your rating</span>\n  <span class=\"rating-readout__thumb {class}\">{svg}</span>\n</div>\n"
        );
    }
    let stars: String = (1..=5)
        .map(|n| {
            star_svg(if n <= rating {
                r#"class="is-on" "#
            } else {
                r#"class="" "#
            })
        })
        .collect();
    format!(
        "<div class=\"rating-readout\">\n  <span>Your rating</span>\n  <span class=\"rating-readout__stars\" role=\"img\" aria-label=\"Rated {rating} of 5\">{stars}</span>\n</div>\n"
    )
}

/// Ratings for these items, keyed by item id.
pub fn user_items_by_item(
    conn: &Connection,
    user_id: i64,
    items: &[&Item],
) -> anyhow::Result<std::collections::HashMap<i64, UserItem>> {
    let mut out = std::collections::HashMap::new();
    for item in items {
        if let Some(rating) = UserItem::find(conn, user_id, &item.rating_key())? {
            out.insert(item.id, rating);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn image_tokens_round_trip_ids_with_colons() {
        let owner = ("season".to_string(), "tmdb:1399:2".to_string());
        let url = poster_url_for(Some(&owner), "w500");
        let token = url.trim_start_matches("/images/").trim_end_matches(".jpg");
        assert_eq!(
            decode_image_token(token),
            Some(("season".into(), "tmdb:1399:2".into(), "w500".into()))
        );
    }

    #[test]
    fn rehosts_jellyfin_paths() {
        assert_eq!(
            remote_poster_url(
                Some("/Items/x/Images/Primary?tag=t"),
                "w185",
                Some("http://jf:8096")
            )
            .as_deref(),
            Some("http://jf:8096/Items/x/Images/Primary?tag=t")
        );
        assert_eq!(
            remote_poster_url(Some("/p.jpg"), "w185", None).as_deref(),
            Some("https://image.tmdb.org/t/p/w185/p.jpg")
        );
        assert_eq!(remote_poster_url(None, "w185", None), None);
    }
}
