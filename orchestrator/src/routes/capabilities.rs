//! `GET /v1/capabilities` (FR-O1) — advertises what the backend can do so the
//! app can show/hide tool affordances and pick a model.
//!
//! The snapshot is re-probed live (with a short TTL, see `CAPABILITIES_TTL`) so
//! models pulled into the upstream after startup surface without a restart —
//! e.g. the app's pull-to-refresh actually picks up a freshly `ollama pull`ed
//! model.

use axum::extract::State;
use axum::Json;

use crate::state::{AppState, CapabilitySnapshot, CAPABILITIES_TTL};
use crate::{detect_upstream, probe_capabilities};

pub async fn capabilities(State(state): State<AppState>) -> Json<CapabilitySnapshot> {
    let snapshot = state
        .capabilities
        .get_or_refresh(CAPABILITIES_TTL, || async {
            let upstream = detect_upstream(&state.cfg, &state.http).await;
            probe_capabilities(&state.cfg, &state.http, &upstream).await
        })
        .await;
    Json((*snapshot).clone())
}
