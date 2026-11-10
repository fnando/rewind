//! Formatting helpers shared by the templates.

use std::fmt::Write as _;
use std::sync::LazyLock;

use jiff::Timestamp;
use jiff::civil::Date;

use crate::config::Config;
use crate::time;

/// HTML-escapes text.
#[must_use]
pub fn h(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#x27;"),
            _ => out.push(c),
        }
    }
    out
}

/// "5 days", or just the word with `count = false`.
#[must_use]
pub fn pluralize(number: i64, singular: &str, plural: Option<&str>, count: bool) -> String {
    let word = if number == 1 {
        singular.to_string()
    } else {
        plural.map_or_else(|| format!("{singular}s"), String::from)
    };
    if count {
        format!("{number} {word}")
    } else {
        word
    }
}

/// "/avatars/1?v=<mtime>" when the user has uploaded an avatar.
#[must_use]
pub fn avatar_url(config: &Config, user_id: i64) -> Option<String> {
    let modified = std::fs::metadata(config.avatar_path(user_id))
        .ok()?
        .modified()
        .ok()?;
    let secs = modified
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    Some(format!("/avatars/{user_id}?v={secs}"))
}

static LEAD_CHARACTERS: LazyLock<Vec<String>> =
    LazyLock::new(|| serde_json::from_str(super::assets::LEAD_CHARACTERS).unwrap_or_default());

/// A url-safe username suggestion from a famous character's name.
#[must_use]
pub fn random_username_placeholder() -> String {
    if LEAD_CHARACTERS.is_empty() {
        return "username".into();
    }
    let name = &LEAD_CHARACTERS[rand::random_range(0..LEAD_CHARACTERS.len())];
    slug(name)
}

/// ASCII, lowercase, dash-separated.
#[must_use]
pub fn slug(value: &str) -> String {
    let ascii = deunicode::deunicode(value).to_lowercase();
    let mut out = String::new();
    for c in ascii.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_matches('-').to_string()
}

/// A stored instant in the user's zone.
#[must_use]
pub fn local(value: &str, zone: &str) -> Option<jiff::Zoned> {
    time::parse(value).map(|ts| time::local(ts, zone))
}

/// "9:05 PM" in the user's zone.
#[must_use]
pub fn format_time(value: &str, zone: &str) -> String {
    local(value, zone).map_or_else(String::new, |z| z.strftime("%-I:%M %p").to_string())
}

/// A stored instant formatted with `fmt` in the user's zone.
#[must_use]
pub fn format_datetime(value: &str, zone: &str, fmt: &str) -> String {
    local(value, zone).map_or_else(String::new, |z| z.strftime(fmt).to_string())
}

/// "Jul 1, 2026" from "2026-07-01".
#[must_use]
pub fn format_date(value: &str) -> String {
    match value.get(..10).and_then(|d| d.parse::<Date>().ok()) {
        Some(date) => date.strftime("%b %-d, %Y").to_string(),
        None => value.to_string(),
    }
}

/// "Today", "Yesterday", or "Monday, July 1".
#[must_use]
pub fn day_label(date: Date, today: Date) -> String {
    if date == today {
        "Today".into()
    } else if today.yesterday().ok() == Some(date) {
        "Yesterday".into()
    } else {
        date.strftime("%A, %B %-d").to_string()
    }
}

/// An ISO 8601 instant for `<time datetime>`.
#[must_use]
pub fn iso(value: &str) -> String {
    time::parse(value).map_or_else(String::new, |ts: Timestamp| ts.to_string())
}

#[must_use]
pub fn media_type_label(media_type: &str) -> &'static str {
    match media_type {
        "movie" => "Movies",
        "episode" | "series" => "Series",
        "track" | "album" | "artist" | "music_video" => "Music",
        _ => "All",
    }
}

/// "2h 28m" from minutes.
#[must_use]
pub fn format_runtime(minutes: Option<i64>) -> Option<String> {
    let minutes = minutes.filter(|m| *m > 0)?;
    let (h, m) = (minutes / 60, minutes % 60);
    Some(match (h, m) {
        (0, m) => format!("{m}m"),
        (h, 0) => format!("{h}h"),
        (h, m) => format!("{h}h {m}m"),
    })
}

fn length_seconds(ms: Option<i64>) -> Option<i64> {
    let ms = ms.filter(|ms| *ms > 0)?;
    Some((ms + 500) / 1000)
}

/// "3:57" from milliseconds.
#[must_use]
pub fn track_length(ms: Option<i64>) -> Option<String> {
    let total = length_seconds(ms)?;
    Some(format!("{}:{:02}", total / 60, total % 60))
}

/// "PT3M57S" from milliseconds.
#[must_use]
pub fn track_length_iso(ms: Option<i64>) -> Option<String> {
    let total = length_seconds(ms)?;
    Some(format!("PT{}M{}S", total / 60, total % 60))
}

/// "42 min" or "1 hr 5 min" from milliseconds.
#[must_use]
pub fn album_length(ms: Option<i64>) -> Option<String> {
    let total = length_seconds(ms)?;
    let minutes = (total + 30) / 60;
    let (hours, rest) = (minutes / 60, minutes % 60);
    Some(match (hours, rest) {
        (0, _) => format!("{minutes} min"),
        (h, 0) => format!("{h} hr"),
        (h, r) => format!("{h} hr {r} min"),
    })
}

/// Builds a query string from pairs, skipping empty values.
#[must_use]
pub fn query_string(pairs: &[(&str, String)]) -> String {
    let mut out = String::new();
    for (key, value) in pairs.iter().filter(|(_, v)| !v.is_empty()) {
        out.push(if out.is_empty() { '?' } else { '&' });
        let _ = write!(
            out,
            "{key}={}",
            percent_encoding::utf8_percent_encode(value, percent_encoding::NON_ALPHANUMERIC)
        );
    }
    out
}

pub const STAR_SVG: &str = r#"<svg viewBox="0 0 24 24" stroke-width="1.8" stroke-linejoin="round" aria-hidden="true"><path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"/></svg>"#;

#[must_use]
pub fn check_svg(size: u32) -> String {
    format!(
        r#"<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12l5 5 9-10"/></svg>"#
    )
}

pub const PLUS_SVG: &str = r#"<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>"#;

pub const TRASH_SVG: &str = r#"<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/></svg>"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_lengths() {
        assert_eq!(track_length(Some(237_000)).as_deref(), Some("3:57"));
        assert_eq!(track_length_iso(Some(237_000)).as_deref(), Some("PT3M57S"));
        assert_eq!(album_length(Some(2_520_000)).as_deref(), Some("42 min"));
        assert_eq!(album_length(Some(3_900_000)).as_deref(), Some("1 hr 5 min"));
        assert_eq!(album_length(Some(3_600_000)).as_deref(), Some("1 hr"));
        assert_eq!(format_runtime(Some(148)).as_deref(), Some("2h 28m"));
        assert_eq!(format_runtime(Some(45)).as_deref(), Some("45m"));
        assert_eq!(format_runtime(Some(0)), None);
    }

    #[test]
    fn slugs_and_escapes() {
        assert_eq!(slug("Amélie Poulain"), "amelie-poulain");
        assert_eq!(h("<a href=\"x\">"), "&lt;a href=&quot;x&quot;&gt;");
        assert_eq!(pluralize(1, "day", None, true), "1 day");
        assert_eq!(pluralize(3, "day", None, false), "days");
    }

    #[test]
    fn labels_days() {
        let today: Date = "2026-11-09".parse().unwrap();
        assert_eq!(day_label(today, today), "Today");
        assert_eq!(day_label("2026-11-08".parse().unwrap(), today), "Yesterday");
        assert_eq!(
            day_label("2026-11-01".parse().unwrap(), today),
            "Sunday, November 1"
        );
        assert_eq!(format_date("2026-07-01"), "Jul 1, 2026");
    }
}
