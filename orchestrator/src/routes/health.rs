//! Lightweight process liveness endpoint.
//!
//! This intentionally avoids probing Ollama, ComfyUI, code-exec containers, or
//! other dependencies. Use it for "is this HTTP process serving?" checks without
//! tying liveness to backend availability.

use axum::Json;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub version: &'static str,
}

pub async fn healthz() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}
