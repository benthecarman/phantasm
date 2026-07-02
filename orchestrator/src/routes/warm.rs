//! `POST /v1/warm` — best-effort model preload so the first real turn skips
//! cold-start latency. The app calls this on launch once it knows the model.
//!
//! For a native-Ollama upstream this issues a `chat` with no messages, which
//! Ollama treats as a "load" (model into VRAM, zero tokens generated) and keeps
//! resident via an explicit warm-only `keep_alive`. For an OpenAI-compatible
//! upstream there is no equivalent free preload, so this is a no-op. Warming
//! never fails the caller: a backend that is down should not turn launch into an
//! error.

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};

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
    let requested = req
        .model
        .filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| state.cfg.default_model.clone());
    // Research modes ride the model id (`<base>:<mode>`); warm the base model —
    // it's what routes and what the upstream actually loads, same as chat.
    let (model, _preset) = state.cfg.presets().resolve_model(&requested);

    // Bound concurrent load against in-flight generations on the upstream this
    // model routes to (NFR-O2).
    let entry = state.upstreams.route(&model);
    let _permit = entry.sem.acquire().await;
    let warmed = match entry.backend.warm_model(&model).await {
        Ok(warmed) => warmed,
        Err(e) => {
            tracing::warn!(model = %model, error = %e, "warm preload failed");
            false
        }
    };

    Json(WarmResponse { warmed, model })
}
