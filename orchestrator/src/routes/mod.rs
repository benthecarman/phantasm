pub mod capabilities;
pub mod chat;
pub mod warm;

use axum::routing::{get, post};
use axum::{middleware, Router};

use crate::state::AppState;

/// Assemble the router with bearer auth applied to every route.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v1/capabilities", get(capabilities::capabilities))
        .route("/v1/chat/completions", post(chat::chat_completions))
        .route("/v1/warm", post(warm::warm))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::auth::require_bearer,
        ))
        .with_state(state)
}
