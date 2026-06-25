//! Phantasm orchestrator library surface.
//!
//! Exposed so integration tests (and `main`) can build the router and bootstrap
//! helpers. See `routes::router` for the HTTP surface.

pub mod auth;
pub mod config;
pub mod error;
pub mod ollama;
pub mod openai;
pub mod orchestrator;
pub mod routes;
pub mod state;
pub mod tools;

use std::sync::Arc;
use std::time::Duration;

use tracing::warn;

use crate::config::Config;
use crate::ollama::{OllamaClient, UpstreamChatBackend, UpstreamKind};
use crate::openai::OpenAICompatibleClient;
use crate::state::{CapabilitySnapshot, ToolFlags};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const OLLAMA_READ_TIMEOUT: Duration = Duration::from_secs(120);
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone)]
pub struct UpstreamDetection {
    pub kind: UpstreamKind,
    pub models: Vec<String>,
}

/// Detect which upstream chat API is exposed by `OLLAMA_BASE_URL`.
///
/// Native Ollama is preferred because it has the tool-call behavior this
/// orchestrator was built around. If `/api/tags` is unavailable, fall back to
/// OpenAI-compatible `/v1/models`.
pub async fn detect_upstream(cfg: &Config, http: &reqwest::Client) -> UpstreamDetection {
    let probe_ollama = OllamaClient::new(http.clone(), cfg.ollama_base.clone());
    if let Ok(Ok(models)) = tokio::time::timeout(PROBE_TIMEOUT, probe_ollama.list_models()).await {
        return UpstreamDetection {
            kind: UpstreamKind::NativeOllama,
            models,
        };
    }

    if let Ok(Ok(models)) = tokio::time::timeout(
        PROBE_TIMEOUT,
        OpenAICompatibleClient::list_models(
            http,
            &cfg.ollama_base,
            cfg.upstream_api_key.as_deref(),
        ),
    )
    .await
    {
        return UpstreamDetection {
            kind: UpstreamKind::OpenAICompatible,
            models,
        };
    }

    warn!("could not detect upstream type; defaulting to native Ollama mode");
    UpstreamDetection {
        kind: UpstreamKind::NativeOllama,
        models: Vec::new(),
    }
}

/// Compute the capabilities manifest from config + bounded startup probes (FR-O1).
pub async fn probe_capabilities(
    cfg: &Config,
    http: &reqwest::Client,
    upstream: &UpstreamDetection,
) -> CapabilitySnapshot {
    let models = if !cfg.models.is_empty() {
        cfg.models.clone()
    } else if !upstream.models.is_empty() {
        upstream.models.clone()
    } else {
        warn!("could not list upstream models at startup; advertising none");
        Vec::new()
    };

    // Vision is only knowable for native Ollama (via `/api/show`). For an
    // OpenAI-compatible upstream we can't tell, so we advertise none and the app
    // treats image support as unknown (optimistic).
    let vision_models = match upstream.kind {
        UpstreamKind::NativeOllama => {
            let client = OllamaClient::new(http.clone(), cfg.ollama_base.clone());
            detect_vision_models(&client, &models).await
        }
        UpstreamKind::OpenAICompatible => Vec::new(),
    };

    let web_search = cfg.web_search_usable();
    // One app-facing "image generation" capability covers both server tools
    // (generation + editing); editing rides under it (tools are invisible to
    // the app). Advertise it when either is usable and ComfyUI is reachable.
    let image_generation = (cfg.image_gen_usable() || cfg.image_edit_usable())
        && probe_reachable(http, cfg.comfy_base.as_str(), "/system_stats").await;

    CapabilitySnapshot {
        version: env!("CARGO_PKG_VERSION").to_string(),
        chat: true,
        models,
        vision_models,
        tools: ToolFlags {
            web_search,
            image_generation,
        },
        streaming: "sse",
    }
}

/// Probe each model's `/api/show` capabilities concurrently (best-effort, short
/// timeout) and return those declaring `"vision"`.
async fn detect_vision_models(client: &OllamaClient, models: &[String]) -> Vec<String> {
    let checks = models.iter().map(|model| async move {
        match tokio::time::timeout(PROBE_TIMEOUT, client.model_capabilities(model)).await {
            Ok(Ok(caps)) if caps.iter().any(|c| c == "vision") => Some(model.clone()),
            _ => None,
        }
    });
    futures_util::future::join_all(checks)
        .await
        .into_iter()
        .flatten()
        .collect()
}

/// Cheap reachability check with a short timeout; failures are non-fatal.
pub async fn probe_reachable(http: &reqwest::Client, base: &str, path: &str) -> bool {
    let url = format!("{}{}", base.trim_end_matches('/'), path);
    let request = http.get(url).timeout(PROBE_TIMEOUT).send();
    matches!(
        tokio::time::timeout(PROBE_TIMEOUT, request).await,
        Ok(Ok(resp)) if resp.status().is_success()
    )
}

/// Build `AppState` from a loaded config (shared by `main` and tests).
pub fn build_state(
    cfg: Arc<Config>,
    capabilities: Arc<CapabilitySnapshot>,
    upstream_kind: UpstreamKind,
) -> state::AppState {
    let capabilities = state::CapabilitiesCache::new(capabilities);
    let http = reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        // Per-read only: streaming responses may run indefinitely as long as
        // bytes keep arriving, but a stalled backend will release its turn.
        .read_timeout(OLLAMA_READ_TIMEOUT)
        .build()
        .expect("building HTTP client");
    let upstream = match upstream_kind {
        UpstreamKind::NativeOllama => UpstreamChatBackend::NativeOllama(OllamaClient::new(
            http.clone(),
            cfg.ollama_base.clone(),
        )),
        UpstreamKind::OpenAICompatible => UpstreamChatBackend::OpenAICompatible(
            OpenAICompatibleClient::new(&cfg.ollama_base, cfg.upstream_api_key.as_deref()),
        ),
    };
    state::AppState {
        upstream_sem: Arc::new(tokio::sync::Semaphore::new(cfg.ollama_concurrency)),
        cfg,
        http,
        upstream,
        capabilities,
    }
}
