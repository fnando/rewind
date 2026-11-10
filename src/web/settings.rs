//! Settings: account, avatar, time zone, rating style, password and the
//! connected Jellyfin accounts.

use askama::Template;
use axum::Router;
use axum::extract::{Form, Multipart, Path, Query};
use axum::http::{StatusCode, header};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use serde::Deserialize;

use super::{AppError, Ctx, Page, Result, State, helpers, redirect, render};
use crate::models::source::NewSource;
use crate::models::{Source, User};
use crate::services::{avatar, jellyfin};

pub fn routes() -> Router<State> {
    Router::new()
        .route("/settings", get(index))
        .route("/settings/rating-style", post(rating_style))
        .route("/settings/avatar", post(upload_avatar))
        .route("/settings/avatar/delete", post(delete_avatar))
        .route("/avatars/{user_id}", get(show_avatar))
        .route("/settings/timezone", post(timezone))
        .route(
            "/settings/password",
            get(password_form).post(change_password),
        )
        .route("/settings/sources", post(connect))
        .route("/settings/sources/{id}/toggle", post(toggle))
        .route("/settings/sources/{id}", axum::routing::delete(disconnect))
}

/// A connected account as the settings card shows it.
pub struct SourceCard {
    pub source: Source,
    pub last_sync: String,
    pub current_error: Option<(String, String)>,
    pub previous_error: Option<(String, String)>,
}

#[derive(Template)]
#[template(path = "settings/index.html")]
struct Index {
    page: Page,
    user: User,
    zones: Vec<String>,
    sources: Vec<SourceCard>,
    show_previous_error: bool,
    open_source_form: bool,
    form_url: String,
    form_username: String,
}

const DATETIME: &str = "%a, %b %-d, %Y %-I:%M %p";

fn source_cards(conn: &rusqlite::Connection, user: &User) -> anyhow::Result<Vec<SourceCard>> {
    let mut cards = Vec::new();
    for source in Source::for_user(conn, user.id)? {
        let at = |when: &str| helpers::format_datetime(when, &user.timezone, DATETIME);
        let current_error = source
            .current_error(conn)?
            .map(|e| (e.message, at(&e.created_at)));
        let previous_error = if current_error.is_none() {
            source
                .latest_error(conn)?
                .map(|e| (e.message, at(&e.created_at)))
        } else {
            None
        };
        cards.push(SourceCard {
            last_sync: source.last_synced_at.as_deref().map_or_else(
                || "never".to_string(),
                |s| helpers::format_datetime(s, &user.timezone, "%Y-%m-%d %H:%M"),
            ),
            source,
            current_error,
            previous_error,
        });
    }
    Ok(cards)
}

#[derive(Deserialize, Default)]
struct IndexQuery {
    show_previous_error: Option<String>,
}

async fn index(ctx: Ctx, Query(query): Query<IndexQuery>) -> Result {
    render_index(
        &ctx,
        query.show_previous_error.as_deref() == Some("true"),
        None,
    )
    .await
}

/// The settings page, optionally with the connect form reopened and filled.
async fn render_index(
    ctx: &Ctx,
    show_previous_error: bool,
    form: Option<(String, String)>,
) -> Result {
    let user = ctx.user().clone();
    let sources = {
        let user = user.clone();
        ctx.blocking(move |conn| Ok(source_cards(conn, &user)?))
            .await?
    };
    let open = form.is_some();
    let (form_url, form_username) = form.unwrap_or_default();
    render(&Index {
        page: ctx.page("Settings"),
        user,
        zones: crate::time::zone_names(),
        sources,
        show_previous_error,
        open_source_form: open,
        form_url,
        form_username,
    })
}

#[derive(Deserialize)]
struct RatingStyle {
    rating_style: String,
}

async fn rating_style(ctx: Ctx, Form(form): Form<RatingStyle>) -> Result {
    let id = ctx.user().id;
    ctx.blocking(move |conn| {
        // An unknown style is ignored.
        let _ = User::set_rating_style(conn, id, &form.rating_style);
        Ok(())
    })
    .await?;
    Ok(redirect("/settings"))
}

#[derive(Deserialize)]
struct Timezone {
    timezone: String,
}

async fn timezone(ctx: Ctx, Form(form): Form<Timezone>) -> Result {
    let id = ctx.user().id;
    ctx.blocking(move |conn| {
        let _ = User::set_timezone(conn, id, &form.timezone);
        Ok(())
    })
    .await?;
    Ok(redirect("/settings"))
}

async fn upload_avatar(ctx: Ctx, mut multipart: Multipart) -> Result {
    let mut token = None;
    let mut bytes = Vec::new();
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::BadRequest(e.to_string()))?
    {
        match field.name() {
            Some("authenticity_token") => {
                token = Some(
                    field
                        .text()
                        .await
                        .map_err(|e| AppError::BadRequest(e.to_string()))?,
                );
            }
            Some("avatar") => {
                bytes = field
                    .bytes()
                    .await
                    .map_err(|e| AppError::BadRequest(e.to_string()))?
                    .to_vec();
            }
            _ => {}
        }
    }
    if !super::middleware::token_matches(token.as_deref(), &ctx.session.csrf()) {
        return Ok((StatusCode::FORBIDDEN, "Forbidden").into_response());
    }
    let config = ctx.state.config.clone();
    let id = ctx.user().id;
    let result = tokio::task::spawn_blocking(move || avatar::write(&config, id, &bytes))
        .await
        .map_err(anyhow::Error::from)?;
    if let Err(error) = result {
        ctx.session.error(format!("{error:#}"));
    }
    Ok(redirect("/settings"))
}

async fn delete_avatar(ctx: Ctx) -> Result {
    avatar::delete(&ctx.state.config, ctx.user().id);
    Ok(redirect("/settings"))
}

async fn show_avatar(ctx: Ctx, Path(user_id): Path<i64>) -> Result {
    let path = ctx.state.config.avatar_path(user_id);
    let Ok(bytes) = tokio::fs::read(&path).await else {
        return Err(AppError::NotFound);
    };
    Ok((
        [
            (header::CONTENT_TYPE, "image/jpeg"),
            (header::CACHE_CONTROL, "public, max-age=86400"),
        ],
        bytes,
    )
        .into_response())
}

#[derive(Template)]
#[template(path = "settings/password.html")]
struct Password {
    page: Page,
    user: User,
    error: Option<String>,
}

async fn password_form(ctx: Ctx) -> Result {
    render(&Password {
        page: ctx.page("Change password"),
        user: ctx.user().clone(),
        error: None,
    })
}

#[derive(Deserialize)]
struct PasswordChange {
    #[serde(default)]
    current_password: String,
    #[serde(default)]
    new_password: String,
    #[serde(default)]
    password_confirmation: String,
}

async fn change_password(ctx: Ctx, Form(form): Form<PasswordChange>) -> Result {
    let user = ctx.user().clone();
    let error = if !user.must_change_password && !user.authenticate(&form.current_password) {
        Some("Current password is incorrect.")
    } else if form.new_password.chars().count() < 12 {
        Some("New password must be at least 12 characters.")
    } else if form.new_password != form.password_confirmation {
        Some("Passwords do not match.")
    } else {
        None
    };
    if let Some(error) = error {
        return render(&Password {
            page: ctx.page("Change password"),
            user,
            error: Some(error.into()),
        });
    }
    let id = user.id;
    ctx.blocking(move |conn| Ok(User::set_password(conn, id, &form.new_password, false)?))
        .await?;
    Ok(redirect("/settings"))
}

#[derive(Deserialize)]
struct Connect {
    #[serde(default)]
    url: String,
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: String,
}

/// Why connecting failed: shown to the user, plus detail for the log.
struct ConnectError(String, String);

/// Connects a Jellyfin account: checks the server has the Rewind plugin
/// (no sign-in needed), signs in once for an access token, and stores it
/// encrypted.
async fn connect(ctx: Ctx, Form(form): Form<Connect>) -> Result {
    let url = form.url.trim().to_string();
    let username = form.username.trim().to_string();
    let key = ctx.state.secret_key;
    let user_id = ctx.user().id;
    let attempt = {
        let (url, username) = (url.clone(), username.clone());
        ctx.blocking(move |conn| Ok(link(conn, &key, user_id, &url, &username, &form.password)))
            .await?
    };
    match attempt {
        Ok(()) => Ok(redirect("/settings")),
        Err(ConnectError(message, detail)) => {
            tracing::info!(
                "[settings] jellyfin connection failed for {username:?} at {url:?}: {detail}"
            );
            ctx.session.error(message);
            render_index(&ctx, false, Some((url, username))).await
        }
    }
}

fn link(
    conn: &rusqlite::Connection,
    key: &[u8; 32],
    user_id: i64,
    url: &str,
    username: &str,
    password: &str,
) -> std::result::Result<(), ConnectError> {
    let fail = |message: &str, detail: String| ConnectError(message.into(), detail);
    if url.is_empty() || username.is_empty() {
        return Err(fail(
            "Enter your Jellyfin URL and username.",
            "blank".into(),
        ));
    }
    let client = jellyfin::Client::new(url, None);
    match client.rewind_info() {
        Ok(_) => {}
        Err(jellyfin::Error::PluginMissing(detail)) => {
            return Err(ConnectError(
                format!(
                    "This Jellyfin server doesn't have the Rewind plugin installed. Install it from {}, restart Jellyfin, then connect again.",
                    jellyfin::PLUGIN_URL
                ),
                detail,
            ));
        }
        Err(error) => {
            return Err(fail(
                "Could not reach the Rewind plugin on this Jellyfin server. Check the URL.",
                error.to_string(),
            ));
        }
    }
    let auth = client.authenticate(username, password).map_err(|e| {
        fail(
            "Could not sign in to Jellyfin. Check the URL and credentials.",
            e.to_string(),
        )
    })?;
    let instance_id = auth
        .server_id
        .clone()
        .or_else(|| client.server_id())
        .unwrap_or_default();
    if auth.access_token.is_empty() || auth.user_id.is_empty() || instance_id.is_empty() {
        return Err(fail(
            "Could not sign in to Jellyfin. Check the URL and credentials.",
            "incomplete sign-in response".into(),
        ));
    }
    let created = Source::create(
        conn,
        key,
        &NewSource {
            user_id,
            url,
            external_user_id: &auth.user_id,
            external_user_name: auth.user_name.as_deref(),
            instance_id: &instance_id,
            access_token: &auth.access_token,
        },
    );
    match created {
        Ok(_) => Ok(()),
        Err(error)
            if error
                .downcast_ref::<rusqlite::Error>()
                .is_some_and(crate::db::is_unique_violation) =>
        {
            Err(fail(
                "That Jellyfin account is already connected.",
                error.to_string(),
            ))
        }
        Err(error) => Err(fail("Could not save the connection.", format!("{error:#}"))),
    }
}

/// The user's own source, or 404.
fn own_source(
    conn: &rusqlite::Connection,
    user_id: i64,
    id: i64,
) -> std::result::Result<Source, AppError> {
    Source::find(conn, id)?
        .filter(|s| s.user_id == user_id)
        .ok_or(AppError::NotFound)
}

async fn toggle(ctx: Ctx, Path(id): Path<i64>) -> Result {
    let user_id = ctx.user().id;
    ctx.blocking(move |conn| {
        let source = own_source(conn, user_id, id)?;
        Source::set_enabled(conn, id, !source.enabled)?;
        Ok(())
    })
    .await?;
    Ok(redirect("/settings"))
}

async fn disconnect(ctx: Ctx, Path(id): Path<i64>) -> Result {
    let user_id = ctx.user().id;
    ctx.blocking(move |conn| {
        own_source(conn, user_id, id)?;
        Source::delete(conn, id)?;
        Ok(())
    })
    .await?;
    Ok(redirect("/settings"))
}
