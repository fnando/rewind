//! The web app: axum routes rendering askama templates.
//!
//! Requests pass through `middleware::around`, which loads the signed session
//! cookie, the signed-in user, applies the login and must-change-password
//! gates, checks CSRF and honours `_method` overrides. Handlers then get a
//! `Ctx` and do their database and HTTP work on a blocking thread.

pub mod assets;
pub mod auth;
pub mod cards;
pub mod ctx;
pub mod errors;
pub mod helpers;
pub mod history;
pub mod images;
pub mod info;
pub mod items;
pub mod media;
pub mod middleware;
pub mod session;
pub mod settings;
pub mod stats;

use std::sync::Arc;

use askama::Template;
use axum::Router;
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Response};
use axum_extra::extract::cookie::Key;

use crate::config::Config;
use crate::db::Db;

pub use ctx::{Ctx, Page};

/// Shared by every request.
pub struct AppState {
    pub config: Config,
    pub db: Db,
    pub secret_key: [u8; 32],
    pub cookie_key: Key,
}

pub type State = Arc<AppState>;

impl AppState {
    pub fn new(config: Config, db: Db) -> anyhow::Result<State> {
        let secret_key = config.resolved_secret_key()?;
        let session_secret = config.resolved_session_secret()?;
        // Key needs 64 bytes; hash whatever secret was configured into that.
        let cookie_key = Key::from(&<sha2::Sha512 as sha2::Digest>::digest(&session_secret));
        Ok(Arc::new(Self {
            config,
            db,
            secret_key,
            cookie_key,
        }))
    }
}

/// The routes, wrapped in the request middleware. The middleware sits on an
/// outer router so it runs before routing (a `_method` override must change
/// the method the inner router matches).
pub fn app(state: State) -> Router {
    let inner = routes().with_state(Arc::clone(&state));
    Router::new()
        .fallback_service(inner)
        .layer(axum::middleware::from_fn_with_state(
            state,
            middleware::around,
        ))
}

fn routes() -> Router<State> {
    Router::new()
        .merge(auth::routes())
        .merge(history::routes())
        .merge(items::routes())
        .merge(info::routes())
        .merge(settings::routes())
        .merge(errors::routes())
        .merge(stats::routes())
        .merge(assets::routes())
        .merge(images::routes())
        .fallback(not_found)
}

async fn not_found(ctx: Ctx) -> Response {
    AppError::NotFound.render(&ctx)
}

/// What a handler can fail with.
#[derive(Debug)]
pub enum AppError {
    NotFound,
    BadRequest(String),
    Unprocessable(String),
    Internal(anyhow::Error),
}

impl<E: Into<anyhow::Error>> From<E> for AppError {
    fn from(error: E) -> Self {
        Self::Internal(error.into())
    }
}

#[derive(Template)]
#[template(path = "errors/404.html")]
struct NotFoundPage {
    page: Page,
}

#[derive(Template)]
#[template(path = "errors/500.html")]
struct ErrorPage {
    page: Page,
}

/// Carries a handler's error out to the middleware, which renders it with the
/// request's context.
#[derive(Clone)]
pub struct Failure(pub Arc<std::sync::Mutex<Option<AppError>>>);

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let mut response = StatusCode::INTERNAL_SERVER_ERROR.into_response();
        response
            .extensions_mut()
            .insert(Failure(Arc::new(std::sync::Mutex::new(Some(self)))));
        response
    }
}

impl AppError {
    /// The error page, logging internal errors with the request's context.
    pub fn render(self, ctx: &Ctx) -> Response {
        match self {
            Self::NotFound => {
                let page = ctx.page("Not found");
                let html = NotFoundPage { page }.render().unwrap_or_default();
                (StatusCode::NOT_FOUND, Html(html)).into_response()
            }
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, message).into_response(),
            Self::Unprocessable(message) => {
                (StatusCode::UNPROCESSABLE_ENTITY, message).into_response()
            }
            Self::Internal(error) => {
                tracing::error!("{error:#}");
                if let Ok(conn) = ctx.state.db.get() {
                    crate::models::ErrorLog::record(
                        &conn,
                        "WebError",
                        &error,
                        &ctx.error_context(),
                    );
                }
                let page = ctx.page("Something went wrong");
                let html = ErrorPage { page }.render().unwrap_or_default();
                (StatusCode::INTERNAL_SERVER_ERROR, Html(html)).into_response()
            }
        }
    }
}

/// A handler's result: a response, or an error rendered with the request's
/// context.
pub type Result<T = Response> = std::result::Result<T, AppError>;

/// Renders a template into an HTML response.
pub fn render(template: &impl Template) -> Result {
    Ok(Html(template.render().map_err(anyhow::Error::from)?).into_response())
}

/// Renders a template with a status code.
pub fn render_status(status: StatusCode, template: &impl Template) -> Result {
    Ok((
        status,
        Html(template.render().map_err(anyhow::Error::from)?),
    )
        .into_response())
}

#[must_use]
pub fn redirect(to: &str) -> Response {
    axum::response::Redirect::to(to).into_response()
}
