pub mod capabilities;
pub mod chat;
pub mod images;
pub mod models;
pub mod warm;

use axum::extract::DefaultBodyLimit;
use axum::http::{header, HeaderValue, Method};
use axum::routing::{delete, get, post};
use axum::{middleware, Router};
use tower_http::cors::{AllowOrigin, Any, CorsLayer};

use crate::state::AppState;

/// Assemble the router. Bearer auth gates every route except the image-serving
/// `GET /v1/files/{id}/content`, which is authorized by the signed URL instead
/// (image loaders can't send an `Authorization` header). The Files-style paths
/// mirror OpenAI's binary-by-id convention.
pub fn router(state: AppState) -> Router {
    // Cap the whole request body before we buffer it (the coarse DoS guard, and
    // what overrides axum's silent 2 MiB default that rejected image-bearing
    // histories with a 413). Finer per-image caps live in the chat handler.
    let body_limit = state.cfg.max_request_body_bytes;
    let cors = cors_layer(&state.cfg.cors_allowed_origins);

    // Bearer-gated routes (everything that mutates or reads private model state).
    let authed = Router::new()
        .route("/v1/capabilities", get(capabilities::capabilities))
        .route("/v1/models", get(models::models))
        .route("/v1/chat/completions", post(chat::chat_completions))
        .route("/v1/chat/cancel", post(chat::cancel))
        .route("/v1/warm", post(warm::warm))
        .route("/v1/files/{id}", delete(images::delete_image))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            crate::auth::require_bearer,
        ));

    // Signature-gated, auth-exempt image fetch (Files-style content path), merged
    // alongside the bearer-gated DELETE on the resource.
    let public = Router::new().route("/v1/files/{id}/content", get(images::get_image));

    authed
        .merge(public)
        .layer(DefaultBodyLimit::max(body_limit))
        // CORS is the outermost layer so a browser preflight (OPTIONS) is
        // answered before bearer auth — preflights carry no `Authorization`
        // header. `option_layer` is a no-op when CORS is disabled (the default).
        .layer(tower::util::option_layer(cors))
        .with_state(state)
}

/// Build the CORS layer from the configured allow-list, or `None` when CORS is
/// disabled (empty list — the default). A single `*` entry allows any origin;
/// otherwise origins are matched exactly. Credentials are never enabled: this
/// API authenticates with a bearer header, not cookies, so `*` stays valid.
fn cors_layer(origins: &[String]) -> Option<CorsLayer> {
    if origins.is_empty() {
        return None;
    }
    let layer = CorsLayer::new()
        .allow_methods([Method::GET, Method::POST, Method::DELETE])
        .allow_headers([header::AUTHORIZATION, header::CONTENT_TYPE]);
    let layer = if origins.iter().any(|o| o == "*") {
        layer.allow_origin(Any)
    } else {
        let allowed: Vec<HeaderValue> = origins.iter().filter_map(|o| o.parse().ok()).collect();
        layer.allow_origin(AllowOrigin::list(allowed))
    };
    Some(layer)
}
