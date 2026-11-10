//! `GET /info`: unauthenticated version and health check.

use axum::Json;
use axum::Router;
use axum::routing::get;
use serde_json::{Value, json};

use super::State;

pub fn routes() -> Router<State> {
    Router::new().route("/info", get(info))
}

async fn info() -> Json<Value> {
    Json(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "tzdata_version": crate::services::timezone_data::current_version(),
    }))
}
