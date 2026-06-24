//! `GET /v1/capabilities` (FR-O1) — advertises what the backend can do so the
//! app can show/hide tool affordances and pick a model.

use axum::extract::State;
use axum::Json;

use crate::state::{AppState, CapabilitySnapshot};

pub async fn capabilities(State(state): State<AppState>) -> Json<CapabilitySnapshot> {
    Json((*state.capabilities).clone())
}
