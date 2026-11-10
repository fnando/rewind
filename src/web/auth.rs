//! Sign in and out.

use askama::Template;
use axum::Router;
use axum::extract::Form;
use axum::http::StatusCode;
use axum::routing::{get, post};
use serde::Deserialize;

use super::{Ctx, Page, Result, State, helpers, redirect, render, render_status};
use crate::models::User;

pub fn routes() -> Router<State> {
    Router::new()
        .route("/login", get(show).post(create))
        .route("/logout", post(destroy))
}

#[derive(Template)]
#[template(path = "auth/login.html")]
struct Login {
    page: Page,
    no_users: bool,
    error: Option<String>,
    placeholder: String,
}

fn no_users(conn: &rusqlite::Connection) -> rusqlite::Result<bool> {
    conn.query_row("SELECT NOT EXISTS (SELECT 1 FROM users)", [], |row| {
        row.get(0)
    })
}

async fn show(ctx: Ctx) -> Result {
    if ctx.user.is_some() {
        return Ok(redirect("/"));
    }
    let none = ctx.blocking(|conn| Ok(no_users(conn)?)).await?;
    render(&Login {
        page: ctx.page("Sign in"),
        no_users: none,
        error: None,
        placeholder: helpers::random_username_placeholder(),
    })
}

#[derive(Deserialize)]
struct Credentials {
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: String,
}

async fn create(ctx: Ctx, Form(form): Form<Credentials>) -> Result {
    let (user, none) = ctx
        .blocking(move |conn| {
            let user = User::find_by_username(conn, form.username.trim())?
                .filter(|u| u.authenticate(&form.password));
            if let Some(user) = &user {
                User::touch_login(conn, user.id)?;
            }
            Ok((user, no_users(conn)?))
        })
        .await?;
    if let Some(user) = user {
        ctx.session.sign_in(user.id);
        return Ok(redirect("/"));
    }
    render_status(
        StatusCode::UNAUTHORIZED,
        &Login {
            page: ctx.page("Sign in"),
            no_users: none,
            error: Some("Invalid username or password.".into()),
            placeholder: helpers::random_username_placeholder(),
        },
    )
}

async fn destroy(ctx: Ctx) -> Result {
    ctx.session.clear();
    Ok(redirect("/login"))
}
