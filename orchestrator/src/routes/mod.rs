pub mod capabilities;
pub mod chat;
pub mod images;
pub mod models;
pub mod warm;

use axum::extract::DefaultBodyLimit;
use axum::routing::{delete, get, post};
use axum::{middleware, Router};

use crate::state::AppState;

/// Assemble the router. Bearer auth gates every route except the image-serving
/// `GET /v1/images/{id}`, which is authorized by the signed URL instead (image
/// loaders can't send an `Authorization` header).
pub fn router(state: AppState) -> Router {
    // Cap the whole request body before we buffer it (the coarse DoS guard, and
    // what overrides axum's silent 2 MiB default that rejected image-bearing
    // histories with a 413). Finer per-image caps live in the chat handler.
    let body_limit = state.cfg.max_request_body_bytes;

    // Bearer-gated routes (everything that mutates or reads private model state).
    let authed = Router::new()
        .route("/v1/capabilities", get(capabilities::capabilities))
        .route("/v1/models", get(models::models))
        .route("/v1/chat/completions", post(chat::chat_completions))
        .route("/v1/warm", post(warm::warm))
        .route("/v1/images/{id}", delete(images::delete_image))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::auth::require_bearer,
        ));

    // Signature-gated, auth-exempt image fetch. Merged so it shares the path with
    // the bearer-gated DELETE (distinct methods don't collide).
    let public = Router::new().route("/v1/images/{id}", get(images::get_image));

    authed
        .merge(public)
        .layer(DefaultBodyLimit::max(body_limit))
        .with_state(state)
}
