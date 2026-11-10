mod common;

use axum::http::StatusCode;
use common::{Env, days_ago};
use rewind::models::item::{Attrs, Item};
use rewind::models::{Play, UserItem};
use serde_json::json;

fn movie(env: &Env) -> Item {
    env.item_with(
        "movie",
        "tmdb:27205",
        "Inception",
        Attrs::new()
            .text("release_date", Some("2010-07-16"))
            .int("runtime", Some(148))
            .text("overview", Some("A heist inside dreams."))
            .metadata(&json!({
                "genres": [{"name": "Drama"}, {"name": "Sci-Fi"}],
                "credits": {
                    "crew": [{"job": "Director", "name": "Christopher Nolan"}],
                    "cast": [{"id": 6193, "name": "Leonardo DiCaprio", "character": "Cobb", "profile_path": "/leo.jpg"}]
                }
            })),
    )
}

#[test]
fn a_movie_page_shows_its_details_watches_and_log_form() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let item = movie(&env);
    env.play(user.id, item.id, &days_ago(1), "jellyfin");
    env.play(user.id, item.id, &days_ago(0), "manual");

    let page = browser.get(&format!("/items/{}", item.id));

    assert_eq!(page.status, StatusCode::OK);
    let body = page.body;
    assert!(body.contains("<title>Inception · Rewind</title>"));
    assert!(body.contains("2010 · 2h 28m · Drama, Sci-Fi"));
    assert!(body.contains("Directed by <strong>Christopher Nolan</strong>"));
    assert!(body.contains("Watched 2 times"));
    assert!(body.contains("Last watched"));
    assert!(body.contains("Logged manually"));
    assert!(body.contains("via Jellyfin"));
    assert!(body.contains(r#"type="datetime-local""#));
    assert!(body.contains(r#"name="played_at""#));
    assert!(body.contains("Leonardo DiCaprio"));
    assert!(body.contains("https://www.themoviedb.org/person/6193"));
    assert!(body.contains("What did you think about this movie?"));
}

#[test]
fn rates_and_reviews_an_item() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let item = movie(&env);
    let path = format!("/items/{}", item.id);

    browser.post(&format!("{path}/rating"), &[("rating", "4")]);
    browser.post(&format!("{path}/review"), &[("review", "A classic.")]);
    let rating = UserItem::find(&env.conn, user.id, &item.rating_key())
        .unwrap()
        .unwrap();
    assert_eq!(rating.rating, Some(4));
    assert_eq!(rating.review.as_deref(), Some("A classic."));

    let page = browser.get(&path).body;
    assert!(page.contains(r#"value="4" aria-label="4 stars" aria-pressed="true""#));
    assert!(page.contains("A classic."));
    assert!(page.contains("Written <time"));

    browser.post(&format!("{path}/rating"), &[("rating", "up")]);
    let rating = UserItem::find(&env.conn, user.id, &item.rating_key())
        .unwrap()
        .unwrap();
    assert_eq!(rating.rating, Some(5));
    browser.post(&format!("{path}/rating"), &[("rating", "clear")]);
    browser.post(&format!("{path}/review"), &[("review", "  ")]);
    let rating = UserItem::find(&env.conn, user.id, &item.rating_key())
        .unwrap()
        .unwrap();
    assert_eq!((rating.rating, rating.review), (None, None));
}

#[test]
fn thumbs_users_get_thumbs() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    rewind::models::User::set_rating_style(&env.conn, user.id, "thumbs").unwrap();
    let item = movie(&env);
    let page = browser.get(&format!("/items/{}", item.id)).body;
    assert!(page.contains(r#"value="up" aria-label="Thumbs up""#));
}

#[test]
fn a_missing_item_is_not_found() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    assert_eq!(browser.get("/items/999").status, StatusCode::NOT_FOUND);
}

fn music(env: &Env) -> (Item, Item, Item) {
    let artist = env.create_item("artist", "mbid:artist:a1", "Radiohead");
    let album = env.item_with(
        "album",
        "mbid:release:r1",
        "OK Computer",
        Attrs::new()
            .text("parent_external_id", Some("mbid:artist:a1"))
            .text("release_date", Some("1997-05-21"))
            .metadata(&json!({"artist": "Radiohead", "artist_external_id": "mbid:artist:a1"})),
    );
    let track = env.item_with(
        "track",
        "mbid:rt:t1",
        "Karma Police",
        Attrs::new()
            .text("parent_external_id", Some("mbid:release:r1"))
            .int("runtime", Some(4))
            .metadata(&json!({
                "artist": "Radiohead", "artist_external_id": "mbid:artist:a1",
                "album": "OK Computer", "album_external_id": "mbid:release:r1",
                "track_number": 6, "length_ms": 237_000
            })),
    );
    (artist, album, track)
}

#[test]
fn a_track_page_links_its_artist_and_album() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let (artist, album, track) = music(&env);
    env.play(user.id, track.id, &days_ago(0), "jellyfin");
    let page = browser.get(&format!("/items/{}", track.id)).body;
    assert!(page.contains(&format!(r#"href="/items/{}">Radiohead</a>"#, artist.id)));
    assert!(page.contains(&format!(
        r#"href="/items/{}">OK Computer</a> (1997)"#,
        album.id
    )));
    assert!(page.contains("Played 1 time"));
    assert!(page.contains("Your listens"));
    assert!(!page.contains("Log a watch"));
}

#[test]
fn an_album_page_lists_every_track_in_order_with_plays_and_lengths() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let (_, album, track) = music(&env);
    env.item_with(
        "track",
        "mbid:rt:t0",
        "Airbag",
        Attrs::new()
            .text("parent_external_id", Some("mbid:release:r1"))
            .metadata(&json!({"album_external_id": "mbid:release:r1", "track_number": 1})),
    );
    env.play(user.id, track.id, &days_ago(0), "jellyfin");

    let page = browser.get(&format!("/items/{}", album.id)).body;
    assert!(page.find("Airbag").unwrap() < page.find("Karma Police").unwrap());
    assert!(page.contains("3:57"));
    assert!(page.contains("1 track play"));
    assert!(page.contains("1997 · 2 tracks · 4 min"));
    assert!(page.contains("Your review"));
    assert!(page.contains(&format!("/items/{}/rating", album.id)));
}

#[test]
fn an_album_rating_follows_its_jellyfin_id_across_a_retag() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    let (_, album, _) = music(&env);
    Item::update(
        &env.conn,
        album.id,
        &Attrs::new().text("jellyfin_id", Some("jf-album-1")),
    )
    .unwrap();
    browser.post(&format!("/items/{}/rating", album.id), &[("rating", "5")]);
    let retagged = env.item_with(
        "album",
        "mbid:release:new",
        "OK Computer",
        Attrs::new().text("jellyfin_id", Some("jf-album-1")),
    );
    let page = browser.get(&format!("/items/{}", retagged.id)).body;
    assert!(page.contains(r#"value="5" aria-label="5 stars" aria-pressed="true""#));
}

#[test]
fn an_artist_page_lists_albums_newest_first_by_release_type() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    let (artist, album, _) = music(&env);
    let newer = env.item_with(
        "album",
        "mbid:release:ir",
        "In Rainbows",
        Attrs::new()
            .text("parent_external_id", Some("mbid:artist:a1"))
            .text("release_date", Some("2007-10-10")),
    );
    let page = browser.get(&format!("/items/{}", artist.id)).body;
    assert!(page.contains(">Albums</h2>"));
    assert!(
        page.find(&format!("/items/{}\"", newer.id)).unwrap()
            < page.find(&format!("/items/{}\"", album.id)).unwrap()
    );
    assert!(page.contains("title-hero__poster--square"));
    assert!(page.contains("cover-card cover-card--track"));
    assert!(page.contains(">Album</span>"));
    assert!(page.contains("on-cover"));

    Item::update(
        &env.conn,
        newer.id,
        &Attrs::new().metadata(&json!({"release_type": "ep"})),
    )
    .unwrap();
    let page = browser.get(&format!("/items/{}", artist.id)).body;
    assert!(page.contains(">EPs</h2>"));
    assert!(page.contains(">Other</h2>"));
}

#[test]
fn a_music_video_page_links_its_artist_and_the_artist_lists_it() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    let (artist, _, _) = music(&env);
    let video = env.item_with(
        "music_video",
        "youtube:v1",
        "No Surprises",
        Attrs::new()
            .text("parent_external_id", Some("mbid:artist:a1"))
            .metadata(&json!({"artist": "Radiohead", "artist_external_id": "mbid:artist:a1"})),
    );
    let page = browser.get(&format!("/items/{}", video.id)).body;
    assert!(page.contains("Music Video"));
    assert!(page.contains(&format!(r#"href="/items/{}">Radiohead</a>"#, artist.id)));
    assert!(page.contains("title-hero__poster--video"));
    let page = browser.get(&format!("/items/{}", artist.id)).body;
    assert!(page.contains("Music videos"));
    assert!(page.contains("No Surprises"));
}

#[test]
fn an_episode_page_links_its_show() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let show = env.create_item("series", "tmdb:1399", "Game of Thrones");
    let episode = env.item_with(
        "episode",
        "tmdb:1",
        "The Kingsroad",
        Attrs::new()
            .text("parent_external_id", Some("tmdb:1399"))
            .int("season_number", Some(1))
            .int("episode_number", Some(2))
            .text("release_date", Some("2011-04-24"))
            .metadata(&json!({"series_name": "Game of Thrones"})),
    );
    env.play(user.id, episode.id, &days_ago(0), "manual");
    let page = browser.get(&format!("/items/{}", episode.id)).body;
    assert!(page.contains("<title>Game of Thrones S1E2 · Rewind</title>"));
    assert!(page.contains(&format!(
        r#"<a href="/items/{}">Game of Thrones</a> ·"#,
        show.id
    )));
    assert!(page.contains("S1 · E2 · 2011"));
    assert!(page.contains("What did you think about this episode?"));
}

#[test]
fn a_series_page_shows_seasons_progress_and_episode_names() {
    let mut env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let show = env.item_with(
        "series",
        "tmdb:1399",
        "Game of Thrones",
        Attrs::new().metadata(&json!({
            "number_of_seasons": 2,
            "seasons": [
                {"season_number": 0, "episode_count": 3},
                {"season_number": 1, "episode_count": 2},
                {"season_number": 2, "episode_count": 2}
            ],
            "credits": {"crew": [{"job": "Creator", "name": "David Benioff"}]}
        })),
    );
    let episode = env.item_with(
        "episode",
        "tmdb:5",
        "The Kingsroad",
        Attrs::new()
            .text("parent_external_id", Some("tmdb:1399"))
            .int("season_number", Some(1))
            .int("episode_number", Some(2)),
    );
    env.play(user.id, episode.id, &days_ago(0), "manual");
    env.stub_json(
        "GET",
        "/3/tv/1399/season/1",
        &json!({"episodes": [{"episode_number": 1, "name": "Winter Is Coming"}, {"episode_number": 2, "name": "The Kingsroad", "still_path": "/s.jpg"}]}),
    );

    let page = browser.get(&format!("/items/{}", show.id)).body;
    assert!(page.contains("1 of 4 episodes watched"));
    assert!(page.contains("25%"));
    assert!(page.contains("Created by <strong>David Benioff</strong>"));
    assert!(page.contains(">Season 1</a>"));
    assert!(page.contains(">Season 2</a>"));
    assert!(!page.contains(">Season 0</a>"));
    assert!(page.contains("Winter Is Coming"));
    assert!(page.contains("Mark watched"));
    assert!(page.contains(&format!(
        r#"<a class="play-card__title" href="/items/{}">The Kingsroad</a>"#,
        episode.id
    )));
    assert!(page.contains("https://image.tmdb.org/t/p/w300/s.jpg"));
}

#[test]
fn a_jellyfin_series_lists_its_real_episodes() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let series = env.item_with(
        "series",
        "jellyfin:s1",
        "Porta dos Fundos",
        Attrs::new().metadata(&json!({"source": "jellyfin"})),
    );
    let episode = env.item_with(
        "episode",
        "youtube:v1",
        "Sketch",
        Attrs::new()
            .text("parent_external_id", Some("jellyfin:s1"))
            .text("release_date", Some("2026-07-01"))
            .metadata(&json!({"source": "jellyfin"})),
    );
    env.play(user.id, episode.id, &days_ago(0), "jellyfin");
    let page = browser.get(&format!("/items/{}", series.id)).body;
    assert!(page.contains("1 episode watched"));
    assert!(page.contains("Sketch"));
    assert!(page.contains("Jul 1, 2026"));
    assert!(!page.contains("Mark watched"));
}

#[test]
fn logs_an_episode_from_the_series_page_at_the_picked_time() {
    let mut env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    rewind::models::User::set_timezone(&env.conn, user.id, "America/Los_Angeles").unwrap();
    let show = env.create_item("series", "tmdb:1399", "Game of Thrones");
    env.stub_tmdb_tv(1399, "Game of Thrones");
    env.stub_tmdb_episode(1399, 1, 2, "The Kingsroad");

    let response = browser.post(
        &format!("/items/{}/log-episode", show.id),
        &[
            ("season", "1"),
            ("episode", "2"),
            ("played_at", "2026-10-30T21:15"),
        ],
    );

    assert!(response.redirected_to(&format!("/items/{}", show.id)));
    let id = env.count("SELECT max(id) FROM plays");
    let play = Play::find(&env.conn, id).unwrap().unwrap();
    assert_eq!(play.started_at, "2026-10-31T04:15:00.000000Z");
    let item = Item::find(&env.conn, play.item_id).unwrap().unwrap();
    assert_eq!(item.title, "The Kingsroad");

    let bad = browser.post(
        &format!("/items/{}/log-episode", show.id),
        &[("season", "0"), ("episode", "2")],
    );
    assert_eq!(bad.status, StatusCode::BAD_REQUEST);
}

#[test]
fn searches_tmdb_and_opens_a_result() {
    let mut env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    env.stub_json(
        "GET",
        "/3/search/multi",
        &json!({"results": [
            {"media_type": "movie", "id": 27205, "title": "Inception", "release_date": "2010-07-16", "overview": "Dreams.", "poster_path": "/p.jpg"},
            {"media_type": "person", "id": 1, "name": "Someone"}
        ]}),
    );
    env.stub_tmdb_movie(27_205);

    let page = browser.get("/search?q=inception").body;
    assert!(page.contains("Inception"));
    assert!(page.contains("movie · 2010"));
    assert!(page.contains(r#"value="inception""#));
    assert!(!page.contains("Someone"));

    let response = browser.post(
        "/items/import",
        &[("media_type", "movie"), ("tmdb_id", "27205")],
    );
    let item = Item::find_by_key(&env.conn, "movie", "tmdb:27205")
        .unwrap()
        .unwrap();
    assert!(response.redirected_to(&format!("/items/{}", item.id)));
}

#[test]
fn search_says_when_tmdb_isnt_configured() {
    let mut env = Env::new();
    env.config.tmdb_api_key = None;
    let (mut browser, _) = env.signed_in("fnando");
    let page = browser.get("/search?q=x").body;
    assert!(page.contains("TMDB_API_KEY not configured"));
}
