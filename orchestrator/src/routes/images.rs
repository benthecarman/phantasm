//! Server-hosted image endpoints (FR-O5 URL delivery), shaped after OpenAI's
//! Files API (binary-by-id).
//!
//! `GET /v1/files/{id}/content` serves a stored blob. It is **exempt from bearer
//! auth** (standard markdown image loaders can't attach an `Authorization`
//! header), so authorization comes from the signed query string the server
//! minted — a valid, unexpired HMAC over the id. `DELETE /v1/files/{id}` stays
//! behind bearer auth and lets the app drop a blob when its conversation is
//! deleted.

use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderMap, Response as HttpResponse, StatusCode};
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
    headers: HeaderMap,
) -> Response {
    let Some(store) = state.images.as_ref() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // Deny first on a bad/expired signature so a missing-vs-present blob isn't
    // distinguishable without a valid link.
    if !store.verify(&id, params.exp, &params.sig) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let Some(len) = store.len(&id).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let selected = headers
        .get(header::RANGE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| parse_range(value, len));
    let blob = match selected {
        Some((start, end)) => store.get_range(&id, start, end).await,
        None => store.get(&id).await,
    };
    let Some(blob) = blob else {
        return StatusCode::NOT_FOUND.into_response();
    };
    artifact_response(blob.bytes, blob.content_type, selected, len)
}

fn artifact_response(
    bytes: Vec<u8>,
    mime: &'static str,
    selected: Option<(usize, usize)>,
    total_len: usize,
) -> Response {
    let (status, body, content_range) = match selected {
        Some((start, end)) => (
            StatusCode::PARTIAL_CONTENT,
            bytes,
            Some(format!("bytes {start}-{end}/{total_len}")),
        ),
        None => (StatusCode::OK, bytes, None),
    };
    let mut response = HttpResponse::builder()
        .status(status)
        .header(header::CONTENT_TYPE, mime)
        .header(header::CACHE_CONTROL, "private, max-age=86400, immutable")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::X_CONTENT_TYPE_OPTIONS, "nosniff")
        .header(header::CONTENT_LENGTH, body.len().to_string());
    if let Some(value) = content_range {
        response = response.header(header::CONTENT_RANGE, value);
    }
    response
        .body(Body::from(body))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn parse_range(value: &str, len: usize) -> Option<(usize, usize)> {
    let spec = value.strip_prefix("bytes=")?;
    if spec.contains(',') || len == 0 {
        return None;
    }
    let (start, end) = spec.split_once('-')?;
    if start.is_empty() {
        let suffix = end.parse::<usize>().ok()?.min(len);
        return (suffix > 0).then_some((len - suffix, len - 1));
    }
    let start = start.parse::<usize>().ok()?;
    if start >= len {
        return None;
    }
    let end = if end.is_empty() {
        len - 1
    } else {
        end.parse::<usize>().ok()?.min(len - 1)
    };
    (start <= end).then_some((start, end))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_media_byte_ranges() {
        assert_eq!(parse_range("bytes=0-3", 10), Some((0, 3)));
        assert_eq!(parse_range("bytes=4-", 10), Some((4, 9)));
        assert_eq!(parse_range("bytes=-3", 10), Some((7, 9)));
        assert_eq!(parse_range("bytes=99-", 10), None);
        assert_eq!(parse_range("bytes=0-1,3-4", 10), None);
    }
}
