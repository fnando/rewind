mod common;

use axum::http::StatusCode;
use common::{Env, KEY};
use mockito::Mock;
use rewind::models::{ErrorLog, Source, User};
use serde_json::json;

fn stub_plugin_info(env: &mut Env, status: usize) -> Mock {
    env.server
        .mock("GET", "/Rewind/Info")
        .with_status(status)
        .with_body(
            json!({"id": "6bcfddb4c3fb48f6996f5b02d07e3e62", "name": "Rewind", "version": "1.0.0"})
                .to_string(),
        )
        .create()
}

fn stub_auth(env: &mut Env, user_id: &str, server_id: &str, name: &str) -> Mock {
    env.server
        .mock("POST", "/Users/AuthenticateByName")
        .with_body(
            json!({"AccessToken": "secret-token", "User": {"Id": user_id, "Name": name}, "ServerId": server_id})
                .to_string(),
        )
        .create()
}

fn connect(browser: &mut common::Browser, url: &str) -> common::Response {
    browser.post(
        "/settings/sources",
        &[("url", url), ("username", "fnando"), ("password", "pw")],
    )
}

#[test]
fn connecting_creates_an_encrypted_source_with_the_username() {
    let mut env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    stub_plugin_info(&mut env, 200);
    stub_auth(&mut env, "jf-42", "srv-42", "jelly-fnando");

    let response = connect(&mut browser, &format!("{}/", env.url()));

    assert!(response.redirected_to("/settings"));
    let sources = Source::for_user(&env.conn, user.id).unwrap();
    assert_eq!(sources.len(), 1);
    let source = &sources[0];
    assert_eq!(source.url, env.url());
    assert_eq!(source.external_user_id, "jf-42");
    assert_eq!(source.instance_id, "srv-42");
    assert_eq!(source.external_user_name.as_deref(), Some("jelly-fnando"));
    assert_ne!(source.credentials, "secret-token");
    assert_eq!(source.access_token(&KEY).unwrap(), "secret-token");

    let page = browser.get("/settings").body;
    assert!(page.contains("Signed in as <strong>jelly-fnando</strong>"));
}

#[test]
fn a_server_without_the_plugin_is_rejected_before_signing_in() {
    let mut env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    stub_plugin_info(&mut env, 404);
    let auth = stub_auth(&mut env, "u-1", "srv-1", "fnando").expect(0);

    let response = connect(&mut browser, &env.url());

    assert!(response.body.contains("Rewind plugin installed"));
    assert!(Source::for_user(&env.conn, user.id).unwrap().is_empty());
    auth.assert();
}

#[test]
fn an_unreachable_plugin_is_rejected() {
    let mut env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    stub_plugin_info(&mut env, 500);
    let response = connect(&mut browser, &env.url());
    assert!(response.body.contains("Could not reach the Rewind plugin"));
}

#[test]
fn bad_credentials_reopen_the_form_prefilled() {
    let mut env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    stub_plugin_info(&mut env, 200);
    env.server
        .mock("POST", "/Users/AuthenticateByName")
        .with_status(401)
        .create();

    let response = connect(&mut browser, &env.url());

    assert!(response.body.contains("Could not sign in to Jellyfin"));
    assert!(
        response
            .body
            .contains(r#"<details class="disclosure" open>"#)
    );
    assert!(response.body.contains(&format!(r#"value="{}""#, env.url())));
    assert!(response.body.contains(r#"value="fnando""#));
    assert!(Source::for_user(&env.conn, user.id).unwrap().is_empty());
}

#[test]
fn the_same_account_cant_be_connected_twice_but_another_account_can() {
    let mut env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    stub_plugin_info(&mut env, 200);
    let first = stub_auth(&mut env, "u-1", "srv-1", "fnando");
    connect(&mut browser, &env.url());
    let response = connect(&mut browser, &env.url());
    assert!(
        response
            .body
            .contains("That Jellyfin account is already connected.")
    );
    first.remove();

    stub_auth(&mut env, "u-2", "srv-1", "partner");
    connect(&mut browser, &env.url());
    assert_eq!(Source::for_user(&env.conn, user.id).unwrap().len(), 2);
}

#[test]
fn errors_show_on_the_card_and_as_a_dot() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let source = env.create_source(user.id, "u-1", "srv-1");

    let page = browser.get("/settings").body;
    assert!(!page.contains("avatar-wrap__dot"));

    Source::record_error(&env.conn, source.id, "boom").unwrap();
    let page = browser.get("/settings").body;
    assert!(page.contains("Sync error"));
    assert!(page.contains("boom"));
    assert!(page.contains("avatar-wrap__dot"));

    Source::save_cursor(&env.conn, source.id, Some(1)).unwrap();
    let page = browser.get("/settings").body;
    assert!(page.contains("See previous error"));
    assert!(!page.contains("avatar-wrap__dot"));
    let page = browser.get("/settings?show_previous_error=true").body;
    assert!(page.contains("Last error (resolved)"));
}

#[test]
fn another_users_error_doesnt_show_a_dot() {
    let env = Env::new();
    let (mut browser, _) = env.signed_in("fnando");
    let other = env.create_user("other");
    let source = env.create_source(other.id, "u-1", "srv-1");
    Source::record_error(&env.conn, source.id, "boom").unwrap();
    assert!(!browser.get("/settings").body.contains("avatar-wrap__dot"));
}

#[test]
fn toggles_and_deletes_only_own_sources() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let mine = env.create_source(user.id, "u-1", "srv-1");
    let other = env.create_user("other");
    let theirs = env.create_source(other.id, "u-2", "srv-1");

    browser.post(&format!("/settings/sources/{}/toggle", mine.id), &[]);
    assert!(!env.reload_source(mine.id).enabled);
    let response = browser.post(&format!("/settings/sources/{}/toggle", theirs.id), &[]);
    assert_eq!(response.status, StatusCode::NOT_FOUND);
    assert!(env.reload_source(theirs.id).enabled);

    let response = browser.post(
        &format!("/settings/sources/{}", mine.id),
        &[("_method", "delete")],
    );
    assert!(response.redirected_to("/settings"));
    assert!(Source::find(&env.conn, mine.id).unwrap().is_none());
}

#[test]
fn saves_the_timezone_and_rating_style() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    browser.post("/settings/timezone", &[("timezone", "America/Sao_Paulo")]);
    browser.post("/settings/timezone", &[("timezone", "Mars/Base")]);
    browser.post("/settings/rating-style", &[("rating_style", "thumbs")]);
    let user = User::find(&env.conn, user.id).unwrap().unwrap();
    assert_eq!(user.timezone, "America/Sao_Paulo");
    assert_eq!(user.rating_style, "thumbs");
    let page = browser.get("/settings").body;
    assert!(page.contains(r#"<option value="America/Sao_Paulo" selected>"#));
}

#[test]
fn changing_the_password_checks_the_current_one() {
    let env = Env::new();
    let (mut browser, user) = env.signed_in("fnando");
    let wrong = browser.post(
        "/settings/password",
        &[
            ("current_password", "nope"),
            ("new_password", "another-long-pass"),
            ("password_confirmation", "another-long-pass"),
        ],
    );
    assert!(wrong.body.contains("Current password is incorrect."));
    let short = browser.post(
        "/settings/password",
        &[
            ("current_password", "a-secure-password-123"),
            ("new_password", "short"),
            ("password_confirmation", "short"),
        ],
    );
    assert!(short.body.contains("at least 12 characters"));
    let ok = browser.post(
        "/settings/password",
        &[
            ("current_password", "a-secure-password-123"),
            ("new_password", "another-long-pass"),
            ("password_confirmation", "another-long-pass"),
        ],
    );
    assert!(ok.redirected_to("/settings"));
    assert!(
        User::find(&env.conn, user.id)
            .unwrap()
            .unwrap()
            .authenticate("another-long-pass")
    );
}

#[test]
fn admins_see_the_error_log_and_others_dont() {
    let env = Env::new();
    let (mut admin, _) = env.signed_in("admin");
    ErrorLog::record(
        &env.conn,
        "RuntimeError",
        &anyhow::anyhow!("boom"),
        &json!({"path": "/x"}),
    );
    let list = admin.get("/settings/errors");
    assert!(list.body.contains("1 error"));
    assert!(list.body.contains("boom"));
    assert!(admin.get("/settings").body.contains("View error log"));
    let id = env.count("SELECT max(id) FROM error_logs");
    let detail = admin.get(&format!("/settings/errors/{id}")).body;
    assert!(detail.contains("RuntimeError"));
    assert!(detail.contains("path") && detail.contains("/x"));

    let other = env.create_user("other");
    let _ = other;
    let mut browser = env.browser();
    browser.sign_in("other");
    assert_eq!(
        browser.get("/settings/errors").status,
        StatusCode::NOT_FOUND
    );
    assert!(!browser.get("/settings").body.contains("View error log"));
}
