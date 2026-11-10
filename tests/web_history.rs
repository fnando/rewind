mod common;

use axum::http::StatusCode;
use common::{Env, days_ago};
use rewind::models::Play;
use rewind::models::item::Attrs;
use serde_json::json;

#[test]
fn no_pagination_when_plays_fit_on_a_page() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    for day in 0..2 {
        let item = env.create_item("movie", &format!("tmdb:{day}"), &format!("Day {day}"));
        env.play(user.id, item.id, &days_ago(day), "manual");
    }
    let page = browser.get("/history");
    assert_eq!(page.status, StatusCode::OK);
    assert!(!page.body.contains("pagination"));
}

#[test]
fn pages_span_two_days_of_activity() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let items: Vec<_> = (0..3)
        .map(|day| {
            let item = env.create_item("movie", &format!("tmdb:{day}"), &format!("Day {day}"));
            env.play(user.id, item.id, &days_ago(day), "manual");
            item
        })
        .collect();

    let first = browser.get("/history").body;
    assert!(first.contains(">Older</a>"));
    assert!(!first.contains(">Newer</a>"));
    assert!(first.contains(r#"href="/history?page=2""#));
    assert!(first.contains(&format!(r#"href="/items/{}""#, items[0].id)));
    assert!(first.contains(&format!(r#"href="/items/{}""#, items[1].id)));
    assert!(!first.contains(&format!(r#"href="/items/{}""#, items[2].id)));
    assert!(first.contains("Today"));
    assert!(first.contains("Yesterday"));

    let second = browser.get("/history?page=2").body;
    assert!(second.contains(">Newer</a>"));
    assert!(!second.contains(">Older</a>"));
    assert!(second.contains(&format!(r#"href="/items/{}""#, items[2].id)));
}

#[test]
fn pagination_keeps_the_filter_and_music_includes_videos() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    for day in 0..3 {
        let item = env.create_item("track", &format!("mbid:rt:{day}"), &format!("Song {day}"));
        env.play(user.id, item.id, &days_ago(day), "jellyfin");
    }
    let video = env.create_item("music_video", "youtube:v", "A Video");
    env.play(user.id, video.id, &days_ago(0), "jellyfin");
    let movie = env.create_item("movie", "tmdb:1", "A Movie");
    env.play(user.id, movie.id, &days_ago(0), "manual");

    let page = browser.get("/history?type=track").body;
    assert!(page.contains("/history?type=track&#38;page=2"));
    assert!(page.contains("A Video"));
    assert!(!page.contains("A Movie"));
}

#[test]
fn a_movie_renders_as_a_portrait_card() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let item = env.item_with(
        "movie",
        "tmdb:5",
        "Whiplash",
        Attrs::new().text("release_date", Some("2014-10-10")),
    );
    env.play(user.id, item.id, &days_ago(0), "jellyfin");

    let page = browser.get("/history").body;
    assert!(page.contains("cover-card cover-card--movie"));
    assert!(page.contains(">Movie</span>"));
    assert!(page.contains(&format!(
        r#"<a class="cover-card__title" href="/items/{}">"#,
        item.id
    )));
    assert!(page.contains("2014"));
    assert!(page.contains("Jellyfin"));
    assert!(page.contains("on-cover"));
}

#[test]
fn a_track_shows_its_artist_and_album() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let item = env.item_with(
        "track",
        "mbid:rt:1",
        "Maps",
        Attrs::new().metadata(&json!({"artist": "Yeah Yeah Yeahs", "album": "Fever to Tell"})),
    );
    env.play(user.id, item.id, &days_ago(0), "jellyfin");
    let page = browser.get("/history").body;
    assert!(page.contains("cover-card cover-card--track"));
    assert!(page.contains(">Track</span>"));
    assert!(page.contains("Yeah Yeah Yeahs · Fever to Tell"));
}

#[test]
fn an_episode_titles_the_episode_and_links_the_show() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let show = env.create_item("series", "tmdb:9001", "Ludwig");
    let episode = env.item_with(
        "episode",
        "tmdb:9002",
        "Pilot",
        Attrs::new()
            .text("parent_external_id", Some("tmdb:9001"))
            .int("season_number", Some(1))
            .int("episode_number", Some(2))
            .metadata(&json!({"series_name": "Ludwig"})),
    );
    env.play(user.id, episode.id, &days_ago(0), "manual");
    let page = browser.get("/history").body;
    assert!(page.contains(">Episode</span>"));
    assert!(page.contains(&format!(
        r#"<a class="cover-card__title" href="/items/{}">Pilot</a>"#,
        episode.id
    )));
    assert!(page.contains("S1 · E2 — "));
    assert!(page.contains(&format!(r#"href="/items/{}">Ludwig</a>"#, show.id)));
}

#[test]
fn an_item_without_a_cover_gets_the_placeholder() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let item = env.create_item("movie", "", "No Art");
    env.play(user.id, item.id, &days_ago(0), "manual");
    let page = browser.get("/history").body;
    assert!(page.contains("cover-card__img--placeholder"));
}

fn album_tracks(env: &Env) -> (rewind::models::Item, Vec<rewind::models::Item>) {
    let artist = env.create_item("artist", "mbid:artist:a", "Green Day");
    let album = env.item_with(
        "album",
        "mbid:release:r",
        "Dookie",
        Attrs::new().text("parent_external_id", Some("mbid:artist:a")),
    );
    let _ = artist;
    let tracks = ["Burnout", "Having a Blast", "Chump"]
        .iter()
        .enumerate()
        .map(|(i, title)| {
            env.item_with(
                "track",
                &format!("mbid:rt:{i}"),
                title,
                Attrs::new()
                    .text("parent_external_id", Some("mbid:release:r"))
                    .metadata(&json!({
                        "artist": "Green Day", "artist_external_id": "mbid:artist:a",
                        "album": "Dookie", "album_external_id": "mbid:release:r"
                    })),
            )
        })
        .collect();
    (album, tracks)
}

#[test]
fn consecutive_tracks_from_one_album_collapse_into_a_group() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let (album, tracks) = album_tracks(&env);
    env.play(user.id, tracks[0].id, "2026-11-09T10:27:00Z", "jellyfin");
    env.play(user.id, tracks[1].id, "2026-11-09T10:31:00Z", "jellyfin");
    env.play(user.id, tracks[2].id, "2026-11-09T11:07:00Z", "jellyfin");
    rewind::models::UserItem::set_rating(&env.conn, user.id, &album.rating_key(), Some(4)).unwrap();

    let page = browser.get("/history").body;
    assert!(page.contains("cover-card--group"));
    assert!(page.contains(&format!(r#"href="/items/{}">Dookie</a>"#, album.id)));
    assert!(page.contains("3 tracks"));
    assert!(page.contains("10:27 AM – 11:07 AM"));
    assert_eq!(page.matches("data-album-tracks=\"group-").count(), 3);
    // The album's own rating is on the group card.
    assert!(page.contains(&format!(r#"action="/items/{}/rating""#, album.id)));
    assert!(page.contains(r#"aria-label="4 stars" aria-pressed="true""#));
}

#[test]
fn a_lone_track_isnt_grouped() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let (_, tracks) = album_tracks(&env);
    env.play(user.id, tracks[0].id, &days_ago(0), "jellyfin");
    assert!(!browser.get("/history").body.contains("cover-card--group"));
}

#[test]
fn logs_a_watch_at_the_picked_time_in_the_users_zone() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    rewind::models::User::set_timezone(&env.conn, user.id, "America/Los_Angeles").unwrap();
    let movie = env.create_item("movie", "tmdb:1", "Clayface");

    let response = browser.post(
        "/history",
        &[
            ("item_id", &movie.id.to_string()),
            ("played_at", "2026-10-30T21:15"),
        ],
    );
    assert!(response.redirected_to(&format!("/items/{}", movie.id)));
    let play = Play::find(&env.conn, env.count("SELECT max(id) FROM plays"))
        .unwrap()
        .unwrap();
    assert_eq!(play.started_at, "2026-10-31T04:15:00.000000Z");
    assert_eq!(play.local_date, "2026-10-30");
    assert_eq!(play.local_time, "21:15");
    assert_eq!(play.source, "manual");

    browser.post("/history", &[("item_id", &movie.id.to_string())]);
    assert_eq!(env.count("SELECT count(*) FROM plays"), 2);

    let future = (jiff::Timestamp::now() + jiff::SignedDuration::from_hours(72))
        .to_zoned(jiff::tz::TimeZone::get("America/Los_Angeles").unwrap())
        .strftime("%Y-%m-%dT%H:%M")
        .to_string();
    let response = browser.post(
        "/history",
        &[("item_id", &movie.id.to_string()), ("played_at", &future)],
    );
    assert_eq!(response.status, StatusCode::UNPROCESSABLE_ENTITY);
    let response = browser.post(
        "/history",
        &[
            ("item_id", &movie.id.to_string()),
            ("played_at", "yesterday-ish"),
        ],
    );
    assert_eq!(response.status, StatusCode::BAD_REQUEST);
    assert_eq!(env.count("SELECT count(*) FROM plays"), 2);
}

#[test]
fn tracks_cant_be_logged_by_hand() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    let track = env.create_item("track", "mbid:rt:1", "Song");
    let response = browser.post("/history", &[("item_id", &track.id.to_string())]);
    assert_eq!(response.status, StatusCode::UNPROCESSABLE_ENTITY);
}

#[test]
fn removes_only_your_own_play() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let other = env.create_user("other");
    let movie = env.create_item("movie", "tmdb:1", "M");
    let mine = env.play(user.id, movie.id, &days_ago(0), "manual");
    let theirs = env.play(other.id, movie.id, &days_ago(0), "manual");

    let response = browser.post(&format!("/history/{}", mine.id), &[("_method", "delete")]);
    assert!(response.redirected_to("/history"));
    assert!(Play::find(&env.conn, mine.id).unwrap().is_none());

    let response = browser.post(&format!("/history/{}", theirs.id), &[("_method", "delete")]);
    assert_eq!(response.status, StatusCode::NOT_FOUND);
    assert!(Play::find(&env.conn, theirs.id).unwrap().is_some());
}

#[test]
fn the_root_goes_to_history() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    assert!(browser.get("/").redirected_to("/history"));
}
