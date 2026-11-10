//! Runs around every request: session, signed-in user, access gates, CSRF
//! and `_method` overrides.

use std::sync::Arc;

use axum::body::{Body, to_bytes};
use axum::extract::{Request, State as Extract};
use axum::http::{HeaderMap, Method, StatusCode, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Redirect, Response};
use axum_extra::extract::cookie::{Cookie, SameSite, SignedCookieJar};

use super::ctx::{Ctx, RequestInfo};
use super::session::{self, Session, SessionData};
use super::{Failure, State};
use crate::models::User;

const MAX_FORM_BYTES: usize = 1024 * 1024;

/// Paths anyone may visit without signing in.
fn public(path: &str) -> bool {
    matches!(path, "/login" | "/logout" | "/info")
        || path.starts_with("/images/")
        || super::assets::is_asset(path)
}

pub async fn around(Extract(state): Extract<State>, request: Request, next: Next) -> Response {
    if !host_allowed(&state.config.allowed_hosts, request.headers()) {
        return (StatusCode::FORBIDDEN, "Host not permitted").into_response();
    }

    let jar = SignedCookieJar::from_headers(request.headers(), state.cookie_key.clone());
    let loaded: Option<SessionData> = jar
        .get(session::COOKIE)
        .and_then(|cookie| serde_json::from_str(cookie.value()).ok());
    let original = loaded.clone();
    let mut data = loaded.unwrap_or_default();
    if data.csrf.is_empty() {
        data.csrf = session::new_token();
    }

    let user = match data.user_id {
        Some(id) => load_user(&state, id).await,
        None => None,
    };
    if user.is_none() {
        data.user_id = None;
    }
    let session = Session::new(data);
    let https = request
        .headers()
        .get("x-forwarded-proto")
        .is_some_and(|v| v.as_bytes().eq_ignore_ascii_case(b"https"));

    let response = match gate(&state, request, &session, user).await {
        Ok((request, ctx)) => {
            let mut request = request;
            request.extensions_mut().insert(ctx.clone());
            let response = next.run(request).await;
            match response.extensions().get::<Failure>() {
                Some(failure) => {
                    let error = failure.0.lock().ok().and_then(|mut e| e.take());
                    match error {
                        Some(error) => error.render(&ctx),
                        None => response,
                    }
                }
                None => response,
            }
        }
        Err(response) => *response,
    };

    let current = session.snapshot();
    if original.as_ref() == Some(&current) {
        return response;
    }
    let cookie = Cookie::build((
        session::COOKIE,
        serde_json::to_string(&current).unwrap_or_default(),
    ))
    .path("/")
    .http_only(true)
    .same_site(SameSite::Lax)
    .secure(https)
    .max_age(cookie::time::Duration::days(session::MAX_AGE_DAYS))
    .build();
    (jar.add(cookie), response).into_response()
}

async fn load_user(state: &State, id: i64) -> Option<User> {
    let state = Arc::clone(state);
    tokio::task::spawn_blocking(move || {
        let conn = state.db.get().ok()?;
        User::find(&conn, id).ok().flatten()
    })
    .await
    .ok()
    .flatten()
}

fn host_allowed(allowed: &[String], headers: &HeaderMap) -> bool {
    if allowed.is_empty() {
        return true;
    }
    let host = headers
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or_default();
    let name = host.rsplit_once(':').map_or(host, |(name, port)| {
        if port.bytes().all(|b| b.is_ascii_digit()) {
            name
        } else {
            host
        }
    });
    allowed
        .iter()
        .any(|a| a.eq_ignore_ascii_case(name) || a.eq_ignore_ascii_case(host))
}

/// Applies the access gates and CSRF checks. Returns the (possibly rebuilt)
/// request and its context, or the response to send instead.
async fn gate(
    state: &State,
    request: Request,
    session: &Session,
    user: Option<User>,
) -> Result<(Request, Ctx), Box<Response>> {
    let path = request.uri().path().to_string();
    let info = RequestInfo {
        method: request.method().to_string(),
        path: path.clone(),
        query: request.uri().query().unwrap_or_default().to_string(),
        user_agent: request
            .headers()
            .get(header::USER_AGENT)
            .and_then(|v| v.to_str().ok())
            .map(String::from),
    };

    if user.is_none() && !public(&path) {
        return Err(Box::new(Redirect::to("/login").into_response()));
    }
    if user.as_ref().is_some_and(|u| u.must_change_password)
        && !matches!(path.as_str(), "/logout" | "/settings/password")
        && !super::assets::is_asset(&path)
    {
        return Err(Box::new(Redirect::to("/settings/password").into_response()));
    }

    let request = if matches!(
        *request.method(),
        Method::GET | Method::HEAD | Method::OPTIONS
    ) {
        request
    } else {
        protect(request, session).await?
    };

    let ctx = Ctx {
        state: Arc::clone(state),
        session: session.clone(),
        user,
        request: info,
    };
    Ok((request, ctx))
}

fn forbidden(reason: &str) -> Response {
    tracing::info!("[csrf] rejected: {reason}");
    (StatusCode::FORBIDDEN, "Forbidden").into_response()
}

/// The host part of an Origin or Referer URL.
fn url_host(value: &str) -> Option<String> {
    let url = url::Url::parse(value).ok()?;
    let host = url.host_str()?;
    Some(match url.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_string(),
    })
}

/// CSRF for unsafe methods: the Origin (or Referer) must be this host, and a
/// form must carry the session's token. Url-encoded forms are checked here
/// (and may override the method with `_method`); multipart forms check their
/// token in the handler.
async fn protect(request: Request, session: &Session) -> Result<Request, Box<Response>> {
    let headers = request.headers();
    let host = headers
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or_default()
        .to_string();
    for name in [header::ORIGIN, header::REFERER] {
        if let Some(value) = headers.get(&name).and_then(|v| v.to_str().ok())
            && value != "null"
            && url_host(value).as_deref() != Some(host.as_str())
        {
            return Err(Box::new(forbidden("cross-origin request")));
        }
    }

    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string();
    if content_type.starts_with("multipart/form-data") {
        return Ok(request);
    }
    if !content_type.is_empty() && !content_type.starts_with("application/x-www-form-urlencoded") {
        return Err(Box::new(forbidden("unexpected content type")));
    }

    let (mut parts, body) = request.into_parts();
    let bytes = to_bytes(body, MAX_FORM_BYTES)
        .await
        .map_err(|_| Box::new((StatusCode::PAYLOAD_TOO_LARGE, "Form too large").into_response()))?;
    let fields: Vec<(String, String)> = serde_urlencoded::from_bytes(&bytes).unwrap_or_default();
    let token = fields
        .iter()
        .find(|(k, _)| k == "authenticity_token")
        .map(|(_, v)| v.as_str());
    if !token_matches(token, &session.csrf()) {
        return Err(Box::new(forbidden("missing or wrong authenticity token")));
    }
    if let Some((_, method)) = fields.iter().find(|(k, _)| k == "_method")
        && let Ok(method) = Method::from_bytes(method.to_uppercase().as_bytes())
        && matches!(method, Method::DELETE | Method::PUT | Method::PATCH)
    {
        parts.method = method;
    }
    Ok(Request::from_parts(parts, Body::from(bytes)))
}

/// Constant-time comparison of the submitted token.
#[must_use]
pub fn token_matches(given: Option<&str>, expected: &str) -> bool {
    let Some(given) = given else { return false };
    if expected.is_empty() || given.len() != expected.len() {
        return false;
    }
    given
        .bytes()
        .zip(expected.bytes())
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}
