pub mod capabilities;
pub mod chat;
pub mod models;
pub mod warm;

use axum::extract::DefaultBodyLimit;
use axum::routing::{get, post};
use axum::{middleware, Router};

use crate::state::AppState;

/// Assemble the router with bearer auth applied to every route.
pub fn router(state: AppState) -> Router {
    // Cap the whole request body before we buffer it (the coarse DoS guard, and
    // what overrides axum's silent 2 MiB default that rejected image-bearing
    // histories with a 413). Finer per-image caps live in the chat handler.
    let body_limit = state.cfg.max_request_body_bytes;
    Router::new()
        .route("/v1/capabilities", get(capabilities::capabilities))
        .route("/v1/models", get(models::models))
        .route("/v1/chat/completions", post(chat::chat_completions))
        .route("/v1/warm", post(warm::warm))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::auth::require_bearer,
        ))
        .layer(DefaultBodyLimit::max(body_limit))
        .with_state(state)
}
