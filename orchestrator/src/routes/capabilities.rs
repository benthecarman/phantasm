//! `GET /v1/capabilities` (FR-O1) — advertises what the backend can do so the
//! app can show/hide tool affordances and pick a model.
//!
//! The snapshot is re-probed live (with a short TTL, see `CAPABILITIES_TTL`) so
//! models pulled into the upstream after startup surface without a restart —
//! e.g. the app's pull-to-refresh actually picks up a freshly `ollama pull`ed
//! model.

use axum::extract::State;
use axum::Json;

use crate::probe_capabilities;
use crate::state::{AppState, CapabilitySnapshot, CAPABILITIES_TTL};

pub async fn capabilities(State(state): State<AppState>) -> Json<CapabilitySnapshot> {
    let snapshot = state
        .capabilities
        .get_or_refresh(CAPABILITIES_TTL, || async {
            probe_capabilities(&state.cfg, &state.http, &state.upstreams, false).await
        })
        .await;
    Json((*snapshot).clone())
}
