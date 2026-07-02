//! `GET /metrics` — Prometheus text exposition (bearer-gated like the other
//! API routes; point a scraper at it with `authorization.credentials` set to
//! the Phantasm token). Rendered from the in-memory registry plus a handful of
//! scrape-time gauges; the durable SQLite history is dashboard-only.

use axum::extract::State;
use axum::http::header;
use axum::response::{IntoResponse, Response};

use crate::metrics::LiveGauges;
use crate::state::AppState;

pub(crate) fn live_gauges(state: &AppState) -> LiveGauges {
    let registry = state.turns.snapshot_counts();
    // Summed across upstreams: each entry has its own semaphore (per-host
    // NFR-O2 bound), and these gauges report total in-flight generations.
    let mut max = 0u64;
    let mut inflight = 0u64;
    for entry in state.upstreams.entries() {
        let entry_max = entry.max_concurrency as u64;
        max += entry_max;
        inflight += entry_max.saturating_sub(entry.sem.available_permits() as u64);
    }
    LiveGauges {
        registry_running: registry.running,
        registry_attached: registry.attached,
        registry_detached_running: registry.detached_running,
        registry_buffered: registry.buffered_terminal,
        upstream_inflight: inflight,
        upstream_max: max,
        uptime_seconds: state.metrics.started_at.elapsed().as_secs(),
        version: env!("CARGO_PKG_VERSION"),
    }
}

pub async fn prometheus(State(state): State<AppState>) -> Response {
    let body = crate::metrics::render_prometheus(&state.metrics, &live_gauges(&state));
    (
        [(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        body,
    )
        .into_response()
}
