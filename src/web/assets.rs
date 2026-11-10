//! Static files compiled into the binary.

use std::sync::LazyLock;

use axum::Router;
use axum::http::header;
use axum::response::IntoResponse;
use axum::routing::get;
use sha2::{Digest, Sha256};

use super::State;

const STYLES: &str = include_str!("../../assets/styles.css");
const POSTER_PLACEHOLDER: &str = include_str!("../../assets/poster-placeholder.svg");
const STILL_PLACEHOLDER: &str = include_str!("../../assets/still-placeholder.svg");
pub const LEAD_CHARACTERS: &str = include_str!("../../assets/lead_characters.json");

const CACHE: &str = "public, max-age=31536000, immutable";

static STYLES_DIGEST: LazyLock<String> =
    LazyLock::new(|| hex::encode(&Sha256::digest(STYLES.as_bytes())[..8]));

/// A short hash of the stylesheet, for cache busting.
#[must_use]
pub fn styles_digest() -> &'static str {
    &STYLES_DIGEST
}

#[must_use]
pub fn is_asset(path: &str) -> bool {
    matches!(
        path,
        "/styles.css" | "/poster-placeholder.svg" | "/still-placeholder.svg"
    )
}

pub fn routes() -> Router<State> {
    Router::new()
        .route(
            "/styles.css",
            get(|| async {
                (
                    [
                        (header::CONTENT_TYPE, "text/css"),
                        (header::CACHE_CONTROL, CACHE),
                    ],
                    STYLES,
                )
                    .into_response()
            }),
        )
        .route(
            "/poster-placeholder.svg",
            get(|| async {
                (
                    [
                        (header::CONTENT_TYPE, "image/svg+xml"),
                        (header::CACHE_CONTROL, CACHE),
                    ],
                    POSTER_PLACEHOLDER,
                )
                    .into_response()
            }),
        )
        .route(
            "/still-placeholder.svg",
            get(|| async {
                (
                    [
                        (header::CONTENT_TYPE, "image/svg+xml"),
                        (header::CACHE_CONTROL, CACHE),
                    ],
                    STILL_PLACEHOLDER,
                )
                    .into_response()
            }),
        )
}
