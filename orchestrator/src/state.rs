//! Shared application state, cheaply cloneable (`Arc` internals).

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::sync::{Mutex, Semaphore};

use crate::config::Config;
use crate::ollama::UpstreamChatBackend;

/// How long a probed capabilities snapshot is served before the next request
/// triggers a fresh upstream re-probe. Bounds probe load (and concurrent
/// probes are deduped under the cache lock) while letting newly-pulled models
/// surface without a server restart.
pub const CAPABILITIES_TTL: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub struct AppState {
    pub cfg: Arc<Config>,
    pub http: reqwest::Client,
    pub upstream: UpstreamChatBackend,
    /// Bounds simultaneous in-flight upstream generations (NFR-O2 downstream limit).
    pub upstream_sem: Arc<Semaphore>,
    pub capabilities: CapabilitiesCache,
}

/// TTL-cached capabilities snapshot. Seeded at startup, then refreshed lazily
/// on the first `/v1/capabilities` request after the TTL lapses (see
/// `routes::capabilities`). The lock is held across the re-probe so concurrent
/// requests share one probe instead of stampeding the upstream.
#[derive(Clone)]
pub struct CapabilitiesCache(Arc<Mutex<CacheEntry>>);

struct CacheEntry {
    snapshot: Arc<CapabilitySnapshot>,
    refreshed_at: Instant,
}

impl CapabilitiesCache {
    pub fn new(snapshot: Arc<CapabilitySnapshot>) -> Self {
        CapabilitiesCache(Arc::new(Mutex::new(CacheEntry {
            snapshot,
            refreshed_at: Instant::now(),
        })))
    }

    /// Return the cached snapshot, re-probing first if it is older than `ttl`.
    /// `refresh` is only awaited (and the upstream only touched) on a miss.
    pub async fn get_or_refresh<F, Fut>(&self, ttl: Duration, refresh: F) -> Arc<CapabilitySnapshot>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = CapabilitySnapshot>,
    {
        let mut entry = self.0.lock().await;
        if entry.refreshed_at.elapsed() >= ttl {
            entry.snapshot = Arc::new(refresh().await);
            entry.refreshed_at = Instant::now();
        }
        entry.snapshot.clone()
    }
}

/// What `/v1/capabilities` reports — computed once at startup from config +
/// reachability probes.
#[derive(Debug, Clone, Serialize)]
pub struct CapabilitySnapshot {
    pub version: String,
    pub chat: bool,
    pub models: Vec<String>,
    /// Subset of `models` that accept image input (probed via Ollama `/api/show`).
    /// Lets the app gate image attachments per model. Empty when undetectable
    /// (e.g. an OpenAI-compatible upstream that doesn't advertise vision).
    #[serde(default)]
    pub vision_models: Vec<String>,
    /// Subset of `models` that support tool/function calling (probed via Ollama
    /// `/api/show`). The server tools in `tools` can only be driven by a model in
    /// this list, so the app gates the web-search / image-generation toggles on
    /// both. Empty when undetectable (e.g. an OpenAI-compatible upstream) — the
    /// app then treats tool support as unknown (optimistic).
    #[serde(default)]
    pub tool_models: Vec<String>,
    pub tools: ToolFlags,
    /// Research modes (mode-suffixed model ids) the app may offer, populated from
    /// the server-side preset table — but only when their required tools are
    /// usable (currently `web_search`). Empty otherwise; older clients tolerate
    /// its absence / emptiness (no research UI). Additive, ignorable by standard
    /// OpenAI clients.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub modes: Vec<ModeInfo>,
    pub streaming: &'static str,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct ToolFlags {
    /// App-facing information-tools group. True when at least one read-only
    /// web/utility tool is available; `web_search` itself may still be false as
    /// an individual schema if Brave is not configured.
    pub web_search: bool,
    pub web_fetch: bool,
    pub calculator: bool,
    pub unit_convert: bool,
    pub weather: bool,
    pub maps_places: bool,
    pub market_data: bool,
    pub github: bool,
    pub ocr: bool,
    pub image_generation: bool,
}

/// One advertised research mode, mirroring the `capabilities.modes` JSON: a
/// stable `id` (the model-suffix mode), a human `label`, and the capabilities it
/// `needs` to be usable (the app gates the mode on `needs ⊆ available tools`).
#[derive(Debug, Clone, Serialize)]
pub struct ModeInfo {
    pub id: String,
    pub label: String,
    pub needs: Vec<String>,
}
