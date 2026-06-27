//! Shared application state, cheaply cloneable (`Arc` internals).

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::sync::{Mutex, Semaphore};

use crate::config::Config;
use crate::ollama::UpstreamChatBackend;
use crate::openai::types::ChatMessage;

/// How long a stashed continuation (a turn paused on an app-hosted tool call,
/// holding co-occurring server-call results) survives before eviction. Sized for
/// a user answering a forwarded prompt within a session; a miss degrades
/// gracefully — the model just re-issues the dropped server calls.
pub const CONTINUATION_TTL: Duration = Duration::from_secs(15 * 60);

/// Cap on simultaneously held continuations. Each entry holds a full turn
/// history (potentially several MB of base64 image data), so the cap bounds
/// worst-case memory; the oldest is evicted past it.
pub const CONTINUATION_MAX: usize = 128;

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
    /// Intra-turn continuation store: holds the resolved history of a turn paused
    /// on an app-hosted tool call when server calls co-occurred, so the
    /// follow-up request resumes without re-running (or losing) that server work.
    pub continuations: ContinuationCache,
    /// Server-hosted image blobs, present only when `IMAGE_STORE_DIR` is set.
    /// When absent, image tools fall back to inline base64 delivery.
    pub images: Option<crate::images::BlobStore>,
}

/// Server-side store for turns paused mid-flight on an app-hosted tool call.
///
/// The orchestrator is otherwise stateless across requests (XR-2). The one
/// exception: when a model issues server *and* app tool calls in one response,
/// the server runs its calls, then must end the turn to let the app run its
/// own. Rather than push those server results into the app's history (keeping
/// server tools invisible to it), we stash the resolved history here, keyed by
/// the forwarded app `tool_call_id` the app echoes back, and resume from it on
/// the continuation request. Entries are one-shot, TTL'd, and bounded; a miss
/// (restart, expiry) degrades gracefully to the model re-issuing the calls.
#[derive(Clone, Default)]
pub struct ContinuationCache(Arc<Mutex<HashMap<String, HeldTurn>>>);

struct HeldTurn {
    messages: Vec<ChatMessage>,
    stored_at: Instant,
}

impl ContinuationCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Stash a paused turn's resolved history under `key` (a forwarded app
    /// `tool_call_id`). Purges expired entries and bounds total count first.
    pub async fn stash(&self, key: String, messages: Vec<ChatMessage>) {
        let mut map = self.0.lock().await;
        map.retain(|_, e| e.stored_at.elapsed() < CONTINUATION_TTL);
        if map.len() >= CONTINUATION_MAX {
            if let Some(oldest) = map
                .iter()
                .min_by_key(|(_, e)| e.stored_at)
                .map(|(k, _)| k.clone())
            {
                map.remove(&oldest);
            }
        }
        map.insert(
            key,
            HeldTurn {
                messages,
                stored_at: Instant::now(),
            },
        );
    }

    /// Take (one-shot) the held history matching any of `keys` — the
    /// `tool_call_id`s on the continuation request's trailing tool results.
    /// `None` if absent or expired.
    pub async fn take(&self, keys: &[String]) -> Option<Vec<ChatMessage>> {
        let mut map = self.0.lock().await;
        for key in keys {
            if let Some(entry) = map.remove(key) {
                if entry.stored_at.elapsed() < CONTINUATION_TTL {
                    return Some(entry.messages);
                }
            }
        }
        None
    }
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
