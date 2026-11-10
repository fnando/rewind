mod common;

use axum::http::StatusCode;
use common::{Env, days_ago};
use rewind::models::item::Attrs;
use serde_json::json;

fn seed(env: &Env, user_id: i64) {
    let drama = env.item_with(
        "movie",
        "tmdb:1",
        "Drama",
        Attrs::new().int("runtime", Some(120)).metadata(&json!({
            "genres": [{"name": "Drama"}],
            "credits": {"crew": [{"job": "Director", "name": "Nolan"}], "cast": [{"name": "Leo DiCaprio"}]}
        })),
    );
    let comedy = env.item_with(
        "movie",
        "tmdb:2",
        "Comedy",
        Attrs::new()
            .int("runtime", Some(90))
            .metadata(&json!({"genres": [{"name": "Comedy"}]})),
    );
    env.play(user_id, drama.id, &days_ago(1), "manual");
    env.play(user_id, drama.id, &days_ago(2), "manual");
    env.play(user_id, comedy.id, &days_ago(3), "manual");
}

#[test]
fn the_stats_page_renders_every_section() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    seed(&env, user.id);
    let track = env.item_with(
        "track",
        "mbid:rt:1",
        "Karma Police",
        Attrs::new().int("runtime", Some(4)).metadata(&json!({
            "artist": "Radiohead", "artist_external_id": "mbid:artist:a1",
            "album": "OK Computer", "album_external_id": "mbid:release:r1"
        })),
    );
    env.create_item("artist", "mbid:artist:a1", "Radiohead");
    env.play(user.id, track.id, &days_ago(0), "jellyfin");

    for period in ["week", "month", "year", "all"] {
        for kind in ["all", "movie", "series", "music"] {
            let page = browser.get(&format!("/stats?period={period}&type={kind}"));
            assert_eq!(page.status, StatusCode::OK, "{period}/{kind}");
        }
    }

    let page = browser.get("/stats?period=all").body;
    assert!(page.contains("hero-stat__big\">4<"));
    assert!(page.contains("things played"));
    assert!(page.contains("in front of the screen"));
    assert!(page.contains("donut__seg--music"));
    assert!(page.contains("Your taste"));
    assert!(page.contains("Mostly drama, with a soft spot for comedy."));
    assert!(page.contains("Familiar faces"));
    assert!(page.contains("Leo DiCaprio"));
    assert!(page.contains("Behind the camera"));
    assert!(page.contains("Nolan"));
    assert!(page.contains("On heavy rotation"));
    assert!(
        page.contains("Songs you couldn&#39;t skip")
            || page.contains("Songs you couldn&#x27;t skip")
            || page.contains("Songs you couldn't skip")
    );
    assert!(page.contains("rhythm-chart__peak"));
    assert!(page.contains("heatmap__cell"));
}

#[test]
fn the_streak_card_shows_a_running_streak() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let movie = env.create_item("movie", "tmdb:1", "M");
    env.play(user.id, movie.id, &days_ago(1), "manual");
    env.play(user.id, movie.id, &days_ago(0), "manual");
    let page = browser.get("/stats").body;
    assert!(page.contains("New record"));
    assert!(page.contains("2 days in a row: your longest streak ever."));
}

#[test]
fn a_first_timer_sees_the_streak_call_to_action() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    let page = browser.get("/stats").body;
    assert!(page.contains("No streak yet."));
    assert!(page.contains("streak-card__foot--cta"));
    assert!(page.contains("No time logged yet."));
}

#[test]
fn an_ended_streak_says_when_it_ended() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let movie = env.create_item("movie", "tmdb:1", "M");
    env.play(user.id, movie.id, &days_ago(5), "manual");
    env.play(user.id, movie.id, &days_ago(4), "manual");
    let page = browser.get("/stats").body;
    assert!(page.contains("Your 2 days streak ended on"));
    assert!(page.contains("and it was your best yet"));
    assert!(page.contains("streak-card--idle"));
}
