//! Shared application state, cheaply cloneable (`Arc` internals).

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::sync::Mutex;

use crate::config::Config;
use crate::openai::types::ChatMessage;
use crate::upstreams::UpstreamSet;

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
    /// Every configured upstream model host, in routing-priority order. Each
    /// entry carries its own backend client and concurrency semaphore
    /// (NFR-O2's bound is per-upstream — separate hosts, separate GPUs);
    /// requests route to an upstream by model id (see `UpstreamSet::route`).
    pub upstreams: Arc<UpstreamSet>,
    pub capabilities: CapabilitiesCache,
    /// Intra-turn continuation store: holds the resolved history of a turn paused
    /// on an app-hosted tool call when server calls co-occurred, so the
    /// follow-up request resumes without re-running (or losing) that server work.
    pub continuations: ContinuationCache,
    /// Buffered resumable turns (see `crate::turn_registry`): a streaming turn
    /// started with an `Idempotency-Key` keeps running across client disconnects
    /// and is replayed on reconnect, so a long generation survives the app
    /// backgrounding. Keyed by that header; TTL'd and bounded.
    pub turns: crate::turn_registry::TurnRegistry,
    /// Server-hosted image blobs, present only when `IMAGE_STORE_DIR` is set.
    /// When absent, image tools fall back to inline base64 delivery.
    pub images: Option<crate::images::BlobStore>,
    /// Warm container pools backing the code-execution tools (offline + online
    /// lanes). Built once at startup when the tool is enabled and the runtime is
    /// available; `None` otherwise (the tools are then not offered). Long-lived —
    /// must not be rebuilt per request.
    pub code_exec: Option<crate::tools::code_exec_pool::CodeExecPools>,
    /// In-memory metrics registry (`/metrics` + dashboard live gauges). Holds
    /// the handle to the optional SQLite history store internally.
    pub metrics: Arc<crate::metrics::Metrics>,
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
    pub models: Vec<ModelInfo>,
    pub tool_selectors: Vec<ToolSelector>,
    /// Research modes (mode-suffixed model ids) the app may offer, populated from
    /// the server-side preset table — but only when their required tools are
    /// usable (currently `web_search`). Empty otherwise. Additive, ignorable by
    /// standard OpenAI clients.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub modes: Vec<ModeInfo>,
}

impl CapabilitySnapshot {
    pub fn has_tool_selector(&self, id: &str) -> bool {
        self.tool_selectors.iter().any(|selector| selector.id == id)
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelInfo {
    pub id: String,
    /// Omitted when the server cannot determine per-model support for this
    /// upstream (for example, an OpenAI-compatible server that only exposes
    /// `/v1/models`). Consumers should treat omitted capabilities as unknown, not
    /// unsupported.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<ModelCapabilities>,
    /// Model context window in tokens, when the upstream reports it. This is
    /// the window actually served: for native Ollama the declared length is
    /// clamped to the upstream's num_ctx cap (when injection is enabled), and
    /// for OpenAI-compatible hosts it is what `/v1/models` advertises.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_length: Option<u64>,
    /// Optional OpenAI-compatible reasoning effort values this model accepts,
    /// when configured for its upstream. Native Ollama does not advertise this:
    /// `/api/show` reports thinking support only, not the accepted levels.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reasoning_efforts: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelCapabilities {
    pub completion: bool,
    pub vision: bool,
    pub audio: bool,
    pub tools: bool,
    pub insert: bool,
    pub embedding: bool,
}

impl ModelCapabilities {
    pub fn from_names(names: &[String]) -> Self {
        Self {
            completion: has_capability(names, "completion"),
            vision: has_capability(names, "vision"),
            audio: has_capability(names, "audio"),
            tools: has_capability(names, "tools"),
            insert: has_capability(names, "insert"),
            embedding: has_capability(names, "embedding"),
        }
    }
}

fn has_capability(names: &[String], name: &str) -> bool {
    names.iter().any(|candidate| candidate == name)
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolSelector {
    /// The name the app sends in the standard OpenAI `tools` array to enable this
    /// bucket for a turn. It may map to multiple concrete server-side tools.
    pub id: String,
    pub label: String,
    /// Concrete server tool schema names currently included in this selector.
    pub tools: Vec<String>,
}

/// One advertised research mode, mirroring the `capabilities.modes` JSON: a
/// stable `id` (the model-suffix mode), a human `label`, and the tool selector
/// ids required to use it.
#[derive(Debug, Clone, Serialize)]
pub struct ModeInfo {
    pub id: String,
    pub label: String,
    pub required_tools: Vec<String>,
}
