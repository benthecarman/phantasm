//! `POST /v1/warm` — best-effort model preload so the first real turn skips
//! cold-start latency. The app calls this on launch once it knows the model.
//!
//! For a native-Ollama upstream this issues a `chat` with no messages, which
//! Ollama treats as a "load" (model into VRAM, zero tokens generated) and keeps
//! resident via `keep_alive` (NFR-O8). For an OpenAI-compatible upstream there
//! is no equivalent free preload, so this is a no-op. Warming never fails the
//! caller: a backend that is down should not turn launch into an error.

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::Map;

use crate::ollama::{ChatBackend, UpstreamKind};
use crate::state::AppState;

#[derive(Debug, Default, Deserialize)]
pub struct WarmRequest {
    /// Model to preload; falls back to the configured default.
    pub model: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct WarmResponse {
    pub warmed: bool,
    pub model: String,
}

pub async fn warm(
    State(state): State<AppState>,
    Json(req): Json<WarmRequest>,
) -> Json<WarmResponse> {
    let model = req
        .model
        .filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| state.cfg.default_model.clone());

    // Only native Ollama has a free, zero-token preload.
    if state.upstream.kind() != UpstreamKind::NativeOllama {
        return Json(WarmResponse {
            warmed: false,
            model,
        });
    }

    // Bound concurrent upstream load against in-flight generations (NFR-O2).
    let _permit = state.upstream_sem.acquire().await;
    let warmed = match state
        .upstream
        .chat_once(&model, &[], &[], &Map::new())
        .await
    {
        Ok(_) => true,
        Err(e) => {
            tracing::warn!(model = %model, error = %e, "warm preload failed");
            false
        }
    };

    Json(WarmResponse { warmed, model })
}
