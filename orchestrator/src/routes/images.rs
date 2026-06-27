//! Server-hosted image endpoints (FR-O5 URL delivery), shaped after OpenAI's
//! Files API (binary-by-id).
//!
//! `GET /v1/files/{id}/content` serves a stored blob. It is **exempt from bearer
//! auth** (standard markdown image loaders can't attach an `Authorization`
//! header), so authorization comes from the signed query string the server
//! minted — a valid, unexpired HMAC over the id. `DELETE /v1/files/{id}` stays
//! behind bearer auth and lets the app drop a blob when its conversation is
//! deleted.

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;

use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct SignedParams {
    exp: u64,
    sig: String,
}

/// Serve a stored image, gated by the signed URL rather than bearer auth.
pub async fn get_image(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<SignedParams>,
) -> Response {
    let Some(store) = state.images.as_ref() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // Deny first on a bad/expired signature so a missing-vs-present blob isn't
    // distinguishable without a valid link.
    if !store.verify(&id, params.exp, &params.sig) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let Some(blob) = store.get(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // Content is immutable (id is its hash) and the link is already capability-
    // scoped, so allow private caching.
    (
        [
            (header::CONTENT_TYPE, blob.content_type),
            (header::CACHE_CONTROL, "private, max-age=86400, immutable"),
        ],
        blob.bytes,
    )
        .into_response()
}

/// Delete a stored image (bearer-authed). Idempotent: a missing id still 204s.
pub async fn delete_image(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let Some(store) = state.images.as_ref() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match store.delete(&id).await {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            tracing::warn!(error = %e, "image delete failed");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}
