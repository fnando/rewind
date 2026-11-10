mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use common::Env;
use rewind::models::User;

#[test]
fn the_login_page_suggests_creating_a_user_when_there_are_none() {
    let env = Env::new();
    let mut browser = env.browser();
    let page = browser.get("/login");
    assert_eq!(page.status, StatusCode::OK);
    assert!(page.body.contains("No accounts yet"));
}

#[test]
fn signs_in_and_out() {
    let env = Env::new();
    env.create_user("fnando");
    let mut browser = env.browser();

    let response = browser.sign_in("fnando");
    assert!(response.redirected_to("/"), "{:?}", response.location);
    assert!(
        browser
            .get("/settings")
            .body
            .contains("Signed in as <strong>fnando</strong>")
    );
    let user = User::find_by_username(&env.conn, "fnando")
        .unwrap()
        .unwrap();
    assert!(user.last_login_at.is_some());

    assert!(browser.post("/logout", &[]).redirected_to("/login"));
    assert!(browser.get("/settings").redirected_to("/login"));
}

#[test]
fn rejects_a_wrong_password() {
    let env = Env::new();
    env.create_user("fnando");
    let mut browser = env.browser();
    let response = browser.post("/login", &[("username", "fnando"), ("password", "nope")]);
    assert_eq!(response.status, StatusCode::UNAUTHORIZED);
    assert!(response.body.contains("Invalid username or password."));
}

#[test]
fn pages_need_a_signed_in_user() {
    let env = Env::new();
    let mut browser = env.browser();
    for path in ["/", "/history", "/stats", "/settings", "/avatars/1"] {
        assert!(browser.get(path).redirected_to("/login"), "{path}");
    }
    assert_eq!(browser.get("/info").status, StatusCode::OK);
    assert_eq!(browser.get("/styles.css").status, StatusCode::OK);
}

#[test]
fn a_user_who_must_change_their_password_is_sent_to_do_it() {
    let env = Env::new();
    let user = User::create(&env.conn, "fnando", None, "temporary-pass").unwrap();
    let mut browser = env.browser();
    browser.post(
        "/login",
        &[("username", "fnando"), ("password", "temporary-pass")],
    );
    assert!(browser.get("/settings").redirected_to("/settings/password"));

    let response = browser.post(
        "/settings/password",
        &[
            ("new_password", "a-new-long-password"),
            ("password_confirmation", "a-new-long-password"),
        ],
    );
    assert!(response.redirected_to("/settings"));
    let user = User::find(&env.conn, user.id).unwrap().unwrap();
    assert!(!user.must_change_password);
    assert!(user.authenticate("a-new-long-password"));
}

#[test]
fn forms_without_the_csrf_token_are_rejected() {
    let env = Env::new();
    env.create_user("fnando");
    let mut browser = env.browser();
    browser.get("/login");
    let response = browser.request(
        Request::post("/login")
            .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(Body::from("username=fnando&password=a-secure-password-123"))
            .unwrap(),
    );
    assert_eq!(response.status, StatusCode::FORBIDDEN);
}

#[test]
fn cross_origin_posts_are_rejected() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    let token = browser.csrf();
    let response = browser.request(
        Request::post("/logout")
            .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .header(header::ORIGIN, "https://evil.test")
            .body(Body::from(format!("authenticity_token={token}")))
            .unwrap(),
    );
    assert_eq!(response.status, StatusCode::FORBIDDEN);
}

#[test]
fn unknown_pages_are_not_found() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    let response = browser.get("/nope");
    assert_eq!(response.status, StatusCode::NOT_FOUND);
    assert!(response.body.contains("Not found"));
}

#[test]
fn info_reports_the_version() {
    let env = Env::new();
    let body = env.browser().get("/info").body;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["version"], env!("CARGO_PKG_VERSION"));
}
