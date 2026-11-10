//! The per-request context handed to handlers, and the page frame (title,
//! user, flash) every template's layout reads.

use std::sync::Arc;

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use rusqlite::Connection;
use serde_json::{Value, json};

use super::session::Session;
use super::{AppError, State, helpers};
use crate::models::User;

/// The request's path and query, and client details for error logs.
#[derive(Debug, Clone, Default)]
pub struct RequestInfo {
    pub method: String,
    pub path: String,
    pub query: String,
    pub user_agent: Option<String>,
}

#[derive(Clone)]
pub struct Ctx {
    pub state: State,
    pub session: Session,
    pub user: Option<User>,
    pub request: RequestInfo,
}

impl<S: Send + Sync> FromRequestParts<S> for Ctx {
    type Rejection = AppError;

    fn from_request_parts(
        parts: &mut Parts,
        _state: &S,
    ) -> impl Future<Output = Result<Self, AppError>> + Send {
        let ctx = parts
            .extensions
            .get::<Self>()
            .cloned()
            .ok_or_else(|| AppError::Internal(anyhow::anyhow!("request context missing")));
        std::future::ready(ctx)
    }
}

/// What the layout needs on every page.
#[derive(Debug, Clone, Default)]
pub struct Page {
    pub title: String,
    pub user: Option<User>,
    pub notice: Option<String>,
    pub error: Option<String>,
    pub csrf: String,
    pub path: String,
    pub search: String,
    pub sync_errors: bool,
    pub avatar_url: Option<String>,
    pub styles_digest: &'static str,
    pub version: &'static str,
}

impl Page {
    /// Whether the topbar link for `prefix` is the current section.
    #[must_use]
    pub fn current(&self, prefix: &str) -> bool {
        self.path.starts_with(prefix)
    }

    /// The hidden CSRF field for a form.
    #[must_use]
    pub fn csrf_tag(&self) -> String {
        format!(
            r#"<input type="hidden" name="authenticity_token" value="{}">"#,
            helpers::h(&self.csrf)
        )
    }

    #[must_use]
    pub fn avatar_letter(&self) -> String {
        self.user
            .as_ref()
            .map(|u| {
                u.display_name()
                    .chars()
                    .take(1)
                    .collect::<String>()
                    .to_uppercase()
            })
            .unwrap_or_default()
    }
}

impl Ctx {
    /// The signed-in user. The middleware guarantees one on every route
    /// except the public ones.
    #[must_use]
    pub fn user(&self) -> &User {
        self.user.as_ref().expect("signed in")
    }

    /// The page frame; pops the flash messages.
    #[must_use]
    pub fn page(&self, title: &str) -> Page {
        let (notice, error) = self
            .session
            .with(|data| (data.notice.take(), data.error.take()));
        let (sync_errors, avatar_url) = match &self.user {
            Some(user) => (
                self.state
                    .db
                    .get()
                    .ok()
                    .and_then(|conn| sync_errors(&conn, user.id).ok())
                    .unwrap_or(false),
                helpers::avatar_url(&self.state.config, user.id),
            ),
            None => (false, None),
        };
        Page {
            title: title.to_string(),
            user: self.user.clone(),
            notice,
            error,
            csrf: self.session.csrf(),
            path: self.request.path.clone(),
            search: String::new(),
            sync_errors,
            avatar_url,
            styles_digest: super::assets::styles_digest(),
            version: env!("CARGO_PKG_VERSION"),
        }
    }

    /// Runs database (and HTTP) work on a blocking thread.
    pub async fn blocking<T, F>(&self, f: F) -> Result<T, AppError>
    where
        T: Send + 'static,
        F: FnOnce(&Connection) -> Result<T, AppError> + Send + 'static,
    {
        let state = Arc::clone(&self.state);
        tokio::task::spawn_blocking(move || {
            let conn = state.db.get()?;
            f(&conn)
        })
        .await
        .map_err(|e| AppError::Internal(e.into()))?
    }

    /// The request data that caused an error, with secrets left out.
    #[must_use]
    pub fn error_context(&self) -> Value {
        json!({
            "method": self.request.method,
            "path": if self.request.query.is_empty() {
                self.request.path.clone()
            } else {
                format!("{}?{}", self.request.path, self.request.query)
            },
            "user_id": self.user.as_ref().map(|u| u.id),
            "user_agent": self.request.user_agent,
        })
    }
}

/// Whether the user has a connection with an unresolved sync error.
pub fn sync_errors(conn: &Connection, user_id: i64) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM sources WHERE user_id = ? AND last_error_id IS NOT NULL)",
        [user_id],
        |row| row.get(0),
    )
}
