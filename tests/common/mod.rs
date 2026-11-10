//! Shared fixtures for the integration tests: a temp data dir with a migrated
//! database, one mock server standing in for Jellyfin and TMDB, and
//! factories for users, sources and items.

#![allow(dead_code)]

use mockito::{Matcher, Mock, Server, ServerGuard};
use rewind::config::Config;
use rewind::db;
use rewind::models::item::{Attrs, Item};
use rewind::models::source::NewSource;
use rewind::models::{Source, User};
use rusqlite::Connection;
use serde_json::{Value, json};
use tempfile::TempDir;

pub const KEY: [u8; 32] = [9; 32];

pub struct Env {
    pub dir: TempDir,
    pub server: ServerGuard,
    pub config: Config,
    pub conn: Connection,
}

impl Env {
    pub fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::new();
        let config = Config {
            data_dir: dir.path().to_path_buf(),
            tmdb_api_key: Some("test-tmdb-key".into()),
            secret_key: Some(rewind::crypto::encode(&KEY)),
            session_secret: Some("a".repeat(128)),
            tmdb_url: format!("{}/3", server.url()),
            fanart_url: format!("{}/fanart", server.url()),
            ..Config::default()
        };
        let conn = db::open(&config.db_path(), 100).unwrap();
        db::migrate(&conn).unwrap();
        Self {
            dir,
            server,
            config,
            conn,
        }
    }

    pub fn url(&self) -> String {
        self.server.url()
    }

    pub fn create_user(&self, username: &str) -> User {
        let user = User::create(&self.conn, username, None, "a-secure-password-123").unwrap();
        User::set_password(&self.conn, user.id, "a-secure-password-123", false).unwrap();
        User::find(&self.conn, user.id).unwrap().unwrap()
    }

    pub fn create_source(&self, user_id: i64, external_user_id: &str, instance_id: &str) -> Source {
        Source::create(
            &self.conn,
            &KEY,
            &NewSource {
                user_id,
                url: &self.server.url(),
                external_user_id,
                external_user_name: None,
                instance_id,
                access_token: "tok",
            },
        )
        .unwrap()
    }

    pub fn create_item(&self, media_type: &str, external_id: &str, title: &str) -> Item {
        Item::upsert(
            &self.conn,
            media_type,
            external_id,
            &Attrs::new()
                .text("title", Some(title))
                .int("runtime", Some(120))
                .metadata(&json!({"genres": [{"name": "Drama"}]})),
        )
        .unwrap()
    }

    pub fn reload_source(&self, id: i64) -> Source {
        Source::find(&self.conn, id).unwrap().unwrap()
    }

    pub fn count(&self, sql: &str) -> i64 {
        self.conn.query_row(sql, [], |row| row.get(0)).unwrap()
    }

    // --- Jellyfin stubs ---

    pub fn stub_json(&mut self, method: &str, path: &str, body: &Value) -> Mock {
        self.server
            .mock(method, path)
            .match_query(Matcher::Any)
            .with_header("content-type", "application/json")
            .with_body(body.to_string())
            .create()
    }

    pub fn stub_status(&mut self, method: &str, path: &str, status: usize) -> Mock {
        self.server
            .mock(method, path)
            .match_query(Matcher::Any)
            .with_status(status)
            .create()
    }

    /// Serves the plugin's changes feed, one page per list of entries, each
    /// keyed on the `since` it answers.
    pub fn stub_changes(&mut self, pages: &[Vec<Value>], start: i64) -> Vec<Mock> {
        let mut since = start;
        let mut mocks = Vec::new();
        for (index, entries) in pages.iter().enumerate() {
            let next = entries
                .iter()
                .filter_map(|e| e["seq"].as_i64())
                .max()
                .unwrap_or(since);
            mocks.push(
                self.server
                    .mock("GET", "/Rewind/History/Changes")
                    .match_query(Matcher::UrlEncoded("since".into(), since.to_string()))
                    .with_header("content-type", "application/json")
                    .with_body(
                        json!({"items": entries, "nextSince": next, "hasMore": index < pages.len() - 1})
                            .to_string(),
                    )
                    .create(),
            );
            since = next;
        }
        mocks
    }

    pub fn stub_library_item(&mut self, item: &Value) -> Mock {
        let path = format!("/Users/u-1/Items/{}", item["Id"].as_str().unwrap());
        self.stub_json("GET", &path, item)
    }

    pub fn stub_item_gone(&mut self, id: &str) -> Mock {
        self.stub_status("GET", &format!("/Users/u-1/Items/{id}"), 404)
    }

    // --- TMDB stubs ---

    pub fn stub_tmdb_movie(&mut self, id: i64) -> Mock {
        let body = json!({
            "id": id,
            "title": "Inception",
            "overview": "A heist inside dreams.",
            "release_date": "2010-07-16",
            "poster_path": "/poster.jpg",
            "runtime": 148,
            "genres": [{"id": 18, "name": "Drama"}],
            "credits": {
                "crew": [{"job": "Director", "name": "Christopher Nolan"}],
                "cast": [{"name": "Leonardo DiCaprio"}]
            }
        });
        self.stub_json("GET", &format!("/3/movie/{id}"), &body)
    }

    pub fn stub_tmdb_tv(&mut self, id: i64, name: &str) -> Mock {
        let body = json!({
            "id": id,
            "name": name,
            "genres": [{"name": "Fantasy"}],
            "episode_run_time": [60],
            "seasons": [],
            "credits": {"crew": [{"job": "Creator", "name": "David Benioff"}], "cast": []}
        });
        self.stub_json("GET", &format!("/3/tv/{id}"), &body)
    }

    pub fn stub_tmdb_episode(&mut self, show: i64, season: i64, episode: i64, title: &str) -> Mock {
        let body = json!({
            "id": show * 1000 + season * 100 + episode,
            "name": title,
            "overview": "On the Kingsroad.",
            "air_date": "2011-04-24",
            "still_path": "/still.jpg",
            "runtime": 56,
            "credits": {}
        });
        self.stub_json(
            "GET",
            &format!("/3/tv/{show}/season/{season}/episode/{episode}"),
            &body,
        )
    }

    pub fn stub_tmdb_find_imdb(&mut self, imdb: &str, body: &Value) -> Mock {
        self.stub_json("GET", &format!("/3/find/{imdb}"), body)
    }
}

pub fn movie_item(id: &str) -> Value {
    json!({"Id": id, "Type": "Movie", "Name": "Inception", "ProviderIds": {"Tmdb": "27205"}})
}

/// A changes-feed entry for a completed, scrobbled movie play, with
/// overrides merged in.
pub fn entry(seq: i64, overrides: &Value) -> Value {
    let mut base = json!({
        "id": "p1",
        "seq": seq,
        "itemId": "m1",
        "itemType": "Movie",
        "name": "Inception",
        "startedAt": "2026-10-16T05:00:00Z",
        "status": "completed",
        "source": "playback",
        "scrobbled": true
    });
    if let (Some(base), Some(extra)) = (base.as_object_mut(), overrides.as_object()) {
        for (k, v) in extra {
            base.insert(k.clone(), v.clone());
        }
    }
    base
}

// --- Web ---

use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use http_body_util::BodyExt;
use tower::ServiceExt;

pub struct Response {
    pub status: StatusCode,
    pub location: Option<String>,
    pub body: String,
}

impl Response {
    pub fn redirected_to(&self, path: &str) -> bool {
        self.status.is_redirection() && self.location.as_deref() == Some(path)
    }
}

/// A test browser: keeps the session cookie between requests and fills in
/// the CSRF token on forms.
pub struct Browser {
    pub app: axum::Router,
    pub cookie: Option<String>,
}

impl Env {
    pub fn browser(&self) -> Browser {
        let db = rewind::db::Db::new(self.config.db_path(), 100).unwrap();
        let state = rewind::web::AppState::new(self.config.clone(), db).unwrap();
        Browser {
            app: rewind::web::app(state),
            cookie: None,
        }
    }

    /// A browser signed in as a new user.
    pub fn signed_in(&self, username: &str) -> (Browser, rewind::models::User) {
        let user = self.create_user(username);
        let mut browser = self.browser();
        browser.sign_in(username);
        (browser, user)
    }
}

impl Browser {
    pub fn request(&mut self, request: Request<Body>) -> Response {
        let mut request = request;
        request
            .headers_mut()
            .insert(header::HOST, "rewind.test".parse().unwrap());
        if let Some(cookie) = &self.cookie {
            request
                .headers_mut()
                .insert(header::COOKIE, cookie.parse().unwrap());
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        let response = runtime.block_on(self.app.clone().oneshot(request)).unwrap();
        if let Some(set) = response.headers().get(header::SET_COOKIE) {
            let pair = set.to_str().unwrap().split(';').next().unwrap().to_string();
            self.cookie = Some(pair);
        }
        let status = response.status();
        let location = response
            .headers()
            .get(header::LOCATION)
            .map(|l| l.to_str().unwrap().to_string());
        let bytes = runtime
            .block_on(response.into_body().collect())
            .unwrap()
            .to_bytes();
        Response {
            status,
            location,
            body: String::from_utf8_lossy(&bytes).into_owned(),
        }
    }

    pub fn get(&mut self, path: &str) -> Response {
        self.request(Request::get(path).body(Body::empty()).unwrap())
    }

    /// The session's CSRF token, read from the signed cookie's payload.
    pub fn csrf(&mut self) -> String {
        if self.cookie.is_none() {
            self.get("/login");
        }
        let cookie = self.cookie.clone().unwrap();
        let value = cookie.split_once('=').unwrap().1;
        let decoded = percent_encoding::percent_decode_str(value)
            .decode_utf8()
            .unwrap();
        // A signed cookie is a 44-character signature followed by the value.
        let json: serde_json::Value = serde_json::from_str(&decoded[44..]).unwrap();
        json["csrf"].as_str().unwrap().to_string()
    }

    /// Posts a form with the session's CSRF token.
    pub fn post(&mut self, path: &str, fields: &[(&str, &str)]) -> Response {
        let token = self.csrf();
        let mut pairs: Vec<(&str, &str)> = fields.to_vec();
        pairs.push(("authenticity_token", &token));
        let body = serde_urlencoded::to_string(&pairs).unwrap();
        self.request(
            Request::post(path)
                .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
                .body(Body::from(body))
                .unwrap(),
        )
    }

    pub fn sign_in(&mut self, username: &str) -> Response {
        self.post(
            "/login",
            &[
                ("username", username),
                ("password", "a-secure-password-123"),
            ],
        )
    }
}

impl Env {
    /// Records a manual play for the user at `at` (RFC 3339).
    pub fn play(&self, user_id: i64, item_id: i64, at: &str, source: &str) -> rewind::models::Play {
        rewind::models::Play::create(
            &self.conn,
            &rewind::models::play::NewPlay {
                user_id,
                item_id,
                source: source.into(),
                started_at: Some(at.parse().unwrap()),
                ..Default::default()
            },
        )
        .unwrap()
    }

    /// An item with exactly these attributes on top of a title.
    pub fn item_with(
        &self,
        media_type: &str,
        external_id: &str,
        title: &str,
        attrs: Attrs,
    ) -> Item {
        Item::upsert(
            &self.conn,
            media_type,
            external_id,
            &attrs.text("title", Some(title)),
        )
        .unwrap()
    }
}

/// `now` minus `days` days, as RFC 3339.
pub fn days_ago(days: i64) -> String {
    let at = jiff::Timestamp::now() - jiff::SignedDuration::from_hours(24 * days);
    at.to_string()
}
