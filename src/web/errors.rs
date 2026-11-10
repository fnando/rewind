//! The admin error log.

use askama::Template;
use axum::Router;
use axum::extract::{Path, Query};
use axum::routing::get;
use serde::Deserialize;

use super::{AppError, Ctx, Page, Result, State, helpers, render};
use crate::models::ErrorLog;

const PER_PAGE: i64 = 50;
const DATETIME: &str = "%a, %b %-d, %Y %-I:%M %p";

pub fn routes() -> Router<State> {
    Router::new()
        .route("/settings/errors", get(index))
        .route("/settings/errors/{id}", get(show))
}

/// 404 (not 403) so the page's existence isn't revealed to non-admins.
fn require_admin(ctx: &Ctx) -> std::result::Result<(), AppError> {
    if ctx.user().admin {
        Ok(())
    } else {
        Err(AppError::NotFound)
    }
}

fn page_url(page: i64) -> String {
    if page > 1 {
        format!("/settings/errors?page={page}")
    } else {
        "/settings/errors".into()
    }
}

#[derive(Template)]
#[template(path = "settings/errors/index.html")]
struct Index {
    page: Page,
    total_label: String,
    errors: Vec<(ErrorLog, String)>,
    prev_url: Option<String>,
    next_url: Option<String>,
}

#[derive(Deserialize)]
struct PageQuery {
    page: Option<i64>,
}

async fn index(ctx: Ctx, Query(query): Query<PageQuery>) -> Result {
    require_admin(&ctx)?;
    let number = query.page.unwrap_or(1).max(1);
    let offset = (number - 1) * PER_PAGE;
    let zone = ctx.user().timezone.clone();
    let (total, errors) = ctx
        .blocking(move |conn| {
            Ok((
                ErrorLog::count(conn)?,
                ErrorLog::page(conn, PER_PAGE, offset)?,
            ))
        })
        .await?;
    let has_next = offset + i64::try_from(errors.len()).unwrap_or(0) < total;
    render(&Index {
        page: ctx.page("Errors"),
        total_label: helpers::pluralize(total, "error", None, true),
        errors: errors
            .into_iter()
            .map(|e| {
                let when = helpers::format_datetime(&e.created_at, &zone, DATETIME);
                (e, when)
            })
            .collect(),
        prev_url: (number > 1).then(|| page_url(number - 1)),
        next_url: has_next.then(|| page_url(number + 1)),
    })
}

#[derive(Template)]
#[template(path = "settings/errors/show.html")]
struct Show {
    page: Page,
    error: ErrorLog,
    when: String,
    context: String,
}

async fn show(ctx: Ctx, Path(id): Path<i64>) -> Result {
    require_admin(&ctx)?;
    let error = ctx
        .blocking(move |conn| ErrorLog::find(conn, id)?.ok_or(AppError::NotFound))
        .await?;
    let when = helpers::format_datetime(&error.created_at, &ctx.user().timezone, DATETIME);
    let context = serde_json::to_string_pretty(&error.context).unwrap_or_default();
    render(&Show {
        page: ctx.page(&format!("Error #{}", error.id)),
        error,
        when,
        context,
    })
}
