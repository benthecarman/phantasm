//! `GET /v1/models` — the standard OpenAI model-listing endpoint.
//!
//! Offered so the orchestrator is a complete drop-in OpenAI server: any standard
//! client can discover models, not only our app (which prefers the richer
//! `/v1/capabilities`). Backed by the same TTL-cached capability probe, so a
//! freshly `ollama pull`ed model surfaces here too without a restart.

use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::State;
use axum::Json;
use serde_json::{json, Value};

use crate::state::{AppState, CAPABILITIES_TTL};
use crate::{detect_upstream, probe_capabilities};

pub async fn models(State(state): State<AppState>) -> Json<Value> {
    let snapshot = state
        .capabilities
        .get_or_refresh(CAPABILITIES_TTL, || async {
            let upstream = detect_upstream(&state.cfg, &state.http).await;
            probe_capabilities(&state.cfg, &state.http, &upstream).await
        })
        .await;

    let created = now_secs();
    let data: Vec<Value> = snapshot
        .models
        .iter()
        .map(|model| {
            json!({
                "id": model.id,
                "object": "model",
                "created": created,
                "owned_by": "phantasm",
            })
        })
        .collect();

    Json(json!({ "object": "list", "data": data }))
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
