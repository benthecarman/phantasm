//! Error types.
//!
//! `AppError` is for *pre-stream* failures (before SSE has started) and renders
//! as an OpenAI-shaped error body with an appropriate HTTP status. Once the SSE
//! stream is open the HTTP status is already committed, so mid-stream problems
//! are surfaced as terminal SSE chunks instead (see `openai::sse`).
//!
//! Tool failures are deliberately *non-fatal*: each tool folds its own failure
//! into the `tool`-role message it returns (see `tools::*`), so the orchestrator
//! feeds a short failure note back to the model and lets the turn continue
//! (NFR-O6) rather than surfacing an error here.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("missing or invalid bearer token")]
    Unauthorized,

    #[error("bad request: {0}")]
    BadRequest(String),

    #[error("payload too large: {0}")]
    PayloadTooLarge(String),

    #[error("upstream model host is unreachable: {0}")]
    UpstreamUnreachable(String),

    #[error("upstream model host returned an error: {0}")]
    UpstreamError(String),

    #[error("internal error: {0}")]
    Internal(String),
}

impl AppError {
    fn parts(&self) -> (StatusCode, &'static str) {
        match self {
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "invalid_request_error"),
            AppError::BadRequest(_) => (StatusCode::BAD_REQUEST, "invalid_request_error"),
            AppError::PayloadTooLarge(_) => {
                (StatusCode::PAYLOAD_TOO_LARGE, "invalid_request_error")
            }
            AppError::UpstreamUnreachable(_) => (StatusCode::BAD_GATEWAY, "upstream_error"),
            AppError::UpstreamError(_) => (StatusCode::BAD_GATEWAY, "upstream_error"),
            AppError::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, kind) = self.parts();
        let body = json!({
            "error": {
                "message": self.to_string(),
                "type": kind,
                "code": status.as_u16(),
            }
        });
        (status, Json(body)).into_response()
    }
}
