//! The self-served metrics dashboard.
//!
//! Two routes: `GET /dashboard` (public) returns a static single-file HTML
//! page carrying no data; `GET /dashboard/data` (bearer-gated) returns the
//! JSON snapshot its JS polls — live gauges from the in-memory registry, SQL
//! aggregates from the metrics store, and best-effort live probes (Ollama
//! loaded models, host RAM/CPU/GPU). Both are gated behind
//! `PHANTASM_DASHBOARD` in the router. Per NFR-O7 nothing here carries message
//! content — identifiers, counts, and timings only.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::{Query, State};
use axum::response::Html;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::host_stats::HostStats;
use crate::metrics_store::{self, DashboardHistory};
use crate::ollama::UpstreamKind;
use crate::state::AppState;
use crate::turn_registry::RegistryCounts;

const PAGE: &str = include_str!("dashboard.html");
const OLLAMA_PS_TIMEOUT: Duration = Duration::from_millis(1500);
const UPSTREAM_PROBE_TIMEOUT: Duration = Duration::from_millis(1500);

pub async fn page() -> Html<&'static str> {
    Html(PAGE)
}

#[derive(Debug, Deserialize)]
pub struct DashboardParams {
    /// `3h` (default) | `24h` | `7d`.
    pub range: Option<String>,
    /// Model filter for the range-scoped sections; absent or `all` => all.
    pub model: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct DashboardData {
    pub version: &'static str,
    pub uptime_seconds: u64,
    pub range_seconds: i64,
    pub bucket_seconds: i64,
    pub turns_active: i64,
    pub upstream_inflight: u64,
    pub upstream_max: u64,
    pub registry: RegistryCounts,
    pub images_generated: u64,
    pub http_unauthorized: u64,
    pub sse_disconnects: u64,
    /// SQL aggregates over the selected range; `None` when the store is
    /// disabled or unreadable (the page shows a "no history" note).
    pub history: Option<DashboardHistory>,
    /// `None` when the upstream is not native Ollama.
    pub ollama: Option<OllamaStatus>,
    /// One row per configured upstream, in routing-priority order. The page
    /// shows the table only when more than one is configured — the aggregate
    /// stats above cover the single-upstream case.
    pub upstreams: Vec<UpstreamStatus>,
    pub host: HostStats,
}

#[derive(Debug, Serialize)]
pub struct UpstreamStatus {
    pub name: String,
    /// `"ollama"` or `"openai"` — how the backend is spoken to.
    pub kind: &'static str,
    pub reachable: bool,
    pub inflight: u64,
    pub max_concurrency: u64,
    /// Models this upstream currently claims for routing (pinned or probed).
    pub models: usize,
}

#[derive(Debug, Serialize)]
pub struct OllamaStatus {
    pub reachable: bool,
    pub models: Vec<OllamaLoadedModel>,
}

#[derive(Debug, Serialize)]
pub struct OllamaLoadedModel {
    pub name: String,
    pub size_vram_bytes: Option<u64>,
    pub expires_at: Option<String>,
}

pub async fn data(
    State(state): State<AppState>,
    Query(params): Query<DashboardParams>,
) -> Json<DashboardData> {
    let (range_seconds, bucket_seconds) = match params.range.as_deref() {
        Some("24h") => (24 * 3600, 600),
        Some("7d") => (7 * 24 * 3600, 3600),
        _ => (3 * 3600, 60),
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let since_ts = now - range_seconds;
    let model = params.model.filter(|m| !m.trim().is_empty() && m != "all");

    let history_fut = query_history(&state, since_ts, bucket_seconds, model);
    let ollama_fut = probe_ollama(&state);
    let upstreams_fut = probe_upstreams(&state);
    let host_fut = crate::host_stats::collect();
    let (history, ollama, upstreams, host) =
        tokio::join!(history_fut, ollama_fut, upstreams_fut, host_fut);

    let live = super::metrics::live_gauges(&state);
    Json(DashboardData {
        version: live.version,
        uptime_seconds: live.uptime_seconds,
        range_seconds,
        bucket_seconds,
        turns_active: state.metrics.turns_active.get(),
        upstream_inflight: live.upstream_inflight,
        upstream_max: live.upstream_max,
        registry: state.turns.snapshot_counts(),
        images_generated: state.metrics.images_generated.get(),
        http_unauthorized: state.metrics.http_unauthorized.get(),
        sse_disconnects: state.metrics.sse_disconnects.get(),
        history,
        ollama,
        upstreams,
        host,
    })
}

/// One health row per configured upstream: a bounded live reachability probe
/// (through the backend client, so API keys apply) plus that host's own
/// in-flight/max from its semaphore. Probes run concurrently, so one down
/// host costs the page a single timeout, not one per upstream.
async fn probe_upstreams(state: &AppState) -> Vec<UpstreamStatus> {
    futures_util::future::join_all(state.upstreams.entries().iter().map(|entry| async move {
        let reachable = tokio::time::timeout(UPSTREAM_PROBE_TIMEOUT, entry.backend.list_models())
            .await
            .ok()
            .is_some_and(|r| r.is_ok());
        let max = entry.max_concurrency as u64;
        UpstreamStatus {
            name: entry.name.clone(),
            kind: match entry.kind {
                UpstreamKind::NativeOllama => "ollama",
                UpstreamKind::OpenAICompatible => "openai",
            },
            reachable,
            inflight: max.saturating_sub(entry.sem.available_permits() as u64),
            max_concurrency: max,
            models: entry.models().len(),
        }
    }))
    .await
}

/// Run the range queries on a blocking thread against a read-only connection.
/// Any failure (no store, unopenable file, query error) => `None`.
async fn query_history(
    state: &AppState,
    since_ts: i64,
    bucket_seconds: i64,
    model: Option<String>,
) -> Option<DashboardHistory> {
    let path = state.metrics.store()?.path().to_path_buf();
    tokio::task::spawn_blocking(move || {
        let conn = metrics_store::open_read(&path)
            .map_err(|e| tracing::warn!(error = %e, "dashboard: metrics store unreadable"))
            .ok()?;
        metrics_store::dashboard_history(&conn, since_ts, bucket_seconds, model.as_deref())
            .map_err(|e| tracing::warn!(error = %e, "dashboard: history query failed"))
            .ok()
    })
    .await
    .ok()
    .flatten()
}

/// Live "what's loaded in VRAM" probe against Ollama's `/api/ps`. Only for a
/// native upstream (the first one, when several are configured); unreachable
/// => `reachable: false` so the page shows a down badge instead of hiding the
/// panel.
async fn probe_ollama(state: &AppState) -> Option<OllamaStatus> {
    let entry = state.upstreams.first_of_kind(UpstreamKind::NativeOllama)?;
    let url = entry.base.join("/api/ps").ok()?;
    let resp = state.http.get(url).timeout(OLLAMA_PS_TIMEOUT).send().await;
    let Ok(resp) = resp else {
        return Some(OllamaStatus {
            reachable: false,
            models: Vec::new(),
        });
    };
    if !resp.status().is_success() {
        return Some(OllamaStatus {
            reachable: false,
            models: Vec::new(),
        });
    }
    let body: Value = resp.json().await.unwrap_or(Value::Null);
    let models = body
        .get("models")
        .and_then(Value::as_array)
        .map(|models| {
            models
                .iter()
                .filter_map(|m| {
                    Some(OllamaLoadedModel {
                        name: m.get("name")?.as_str()?.to_string(),
                        size_vram_bytes: m.get("size_vram").and_then(Value::as_u64),
                        expires_at: m
                            .get("expires_at")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Some(OllamaStatus {
        reachable: true,
        models,
    })
}
