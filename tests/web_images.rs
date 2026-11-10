mod common;

use axum::http::StatusCode;
use common::Env;
use rewind::models::item::{Attrs, Item};
use rewind::web::media;
use serde_json::json;

fn url_for(owner: (&str, &str)) -> String {
    media::poster_url_for(Some(&(owner.0.to_string(), owner.1.to_string())), "w500")
}

#[test]
fn a_cached_file_is_served_without_signing_in() {
    let env = Env::new();
    let item = env.create_item("movie", "tmdb:949", "Heat");
    let url = media::poster_url(&item);
    let dir = env.config.image_storage_dir();
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(url.trim_start_matches("/images/")), "CACHED").unwrap();

    let response = env.browser().get(&url);
    assert_eq!(response.status, StatusCode::OK);
    assert_eq!(response.body, "CACHED");
}

#[test]
fn a_miss_downloads_from_a_connected_server_caches_and_heals() {
    let mut env = Env::new();
    let user = env.create_user("fnando");
    env.create_source(user.id, "u-1", "srv-1");
    let album = env.item_with(
        "album",
        "mbid:synthetic:album:abc",
        "B-Sides",
        Attrs::new().text("jellyfin_id", Some("jf-album-1")),
    );
    env.server
        .mock("GET", "/Items/jf-album-1/Images/Primary")
        .with_body("ALBUMART")
        .create();
    let url = media::poster_url(&album);

    let response = env.browser().get(&url);

    assert_eq!(response.status, StatusCode::OK);
    assert_eq!(response.body, "ALBUMART");
    let cached = env
        .config
        .image_storage_dir()
        .join(url.trim_start_matches("/images/"));
    assert_eq!(std::fs::read_to_string(cached).unwrap(), "ALBUMART");
    let healed = Item::find(&env.conn, album.id).unwrap().unwrap();
    assert_eq!(
        healed.poster_path,
        Some(format!("{}/Items/jf-album-1/Images/Primary", env.url()))
    );
}

#[test]
fn a_dead_stored_cover_falls_through_to_jellyfin_artwork() {
    let mut env = Env::new();
    let user = env.create_user("fnando");
    env.create_source(user.id, "u-1", "srv-1");
    let dead = format!("{}/dead.jpg", env.url());
    let album = env.item_with(
        "album",
        "mbid:release:r",
        "B-Sides",
        Attrs::new()
            .text("poster_path", Some(dead.as_str()))
            .text("jellyfin_id", Some("jf-1")),
    );
    env.server
        .mock("GET", "/dead.jpg")
        .with_status(404)
        .create();
    env.server
        .mock("GET", "/Items/jf-1/Images/Primary")
        .with_body("JELLYART")
        .create();

    let response = env.browser().get(&media::poster_url(&album));

    assert_eq!(response.body, "JELLYART");
    let healed = Item::find(&env.conn, album.id).unwrap().unwrap();
    assert!(
        healed
            .poster_path
            .unwrap()
            .ends_with("/Items/jf-1/Images/Primary")
    );
}

#[test]
fn stored_jellyfin_paths_are_rehosted_to_the_connected_server() {
    let mut env = Env::new();
    let user = env.create_user("fnando");
    env.create_source(user.id, "u-1", "srv-1");
    let episode = env.item_with(
        "episode",
        "jellyfin:ep2",
        "Ep2",
        Attrs::new().text(
            "poster_path",
            Some("https://old.example/Items/ep2/Images/Primary?tag=t"),
        ),
    );
    env.server
        .mock("GET", "/Items/ep2/Images/Primary")
        .match_query(mockito::Matcher::UrlEncoded("tag".into(), "t".into()))
        .with_body("IMG2")
        .create();
    assert_eq!(env.browser().get(&media::poster_url(&episode)).body, "IMG2");
}

#[test]
fn a_host_that_isnt_allowed_falls_back_to_the_placeholder() {
    let env = Env::new();
    let artist = env.item_with(
        "artist",
        "mbid:artist:x",
        "X",
        Attrs::new().text("poster_path", Some("https://evil.example/p.jpg")),
    );
    let response = env.browser().get(&media::poster_url(&artist));
    assert!(response.redirected_to("/poster-placeholder.svg"));
}

#[test]
fn an_artist_without_art_is_fetched_from_fanart_and_backfilled() {
    let mut env = Env::new();
    env.config.fanart_api_key = Some("key".into());
    let user = env.create_user("fnando");
    env.create_source(user.id, "u-1", "srv-1");
    let artist = env.create_item("artist", "mbid:artist:abc", "Radiohead");
    let thumb = format!("{}/fanart-thumb.jpg", env.url());
    env.server
        .mock("GET", "/fanart/music/abc")
        .match_query(mockito::Matcher::Any)
        .with_body(json!({"artistthumb": [{"url": thumb}]}).to_string())
        .create();
    env.server
        .mock("GET", "/fanart-thumb.jpg")
        .with_body("ARTBYTES")
        .create();

    let response = env.browser().get(&media::poster_url(&artist));

    assert_eq!(response.body, "ARTBYTES");
    assert_eq!(
        Item::find(&env.conn, artist.id)
            .unwrap()
            .unwrap()
            .poster_path,
        Some(thumb)
    );
}

#[test]
fn a_season_without_a_poster_falls_back_to_the_placeholder() {
    let env = Env::new();
    env.item_with(
        "series",
        "tmdb:1399",
        "GoT",
        Attrs::new().metadata(&json!({"seasons": [{"season_number": 1}]})),
    );
    let response = env.browser().get(&url_for(("season", "tmdb:1399:1")));
    assert!(response.redirected_to("/poster-placeholder.svg"));
}

#[test]
fn tracks_sharing_an_album_share_one_cover_url() {
    let env = Env::new();
    let urls: Vec<String> = (1..=2)
        .map(|n| {
            let track = env.item_with(
                "track",
                &format!("mbid:rt:{n}"),
                "T",
                Attrs::new().metadata(&json!({"album_external_id": "mbid:release:1"})),
            );
            media::poster_url(&track)
        })
        .collect();
    assert_eq!(urls[0], urls[1]);
}

#[test]
fn malformed_tokens_are_not_found() {
    let env = Env::new();
    assert_eq!(
        env.browser().get("/images/..%2Fsecret.jpg").status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        env.browser().get("/images/zz.png").status,
        StatusCode::NOT_FOUND
    );
}
