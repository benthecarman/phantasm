//! Phantasm orchestrator library surface.
//!
//! Exposed so integration tests (and `main`) can build the router and bootstrap
//! helpers. See `routes::router` for the HTTP surface.

pub mod auth;
pub mod config;
pub mod error;
pub mod images;
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
use crate::state::{CapabilitySnapshot, ModelCapabilities, ModelInfo, ToolSelector};

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

    // Per-model vision + tool support is only knowable for native Ollama (via
    // `/api/show`). For an OpenAI-compatible upstream we omit model capabilities
    // so clients can distinguish unknown from known-unsupported.
    let model_metadata = match upstream.kind {
        UpstreamKind::NativeOllama => {
            let client = OllamaClient::new(http.clone(), cfg.ollama_base.clone());
            detect_model_metadata(&client, &models).await
        }
        UpstreamKind::OpenAICompatible => vec![(None, None); models.len()],
    };
    let models: Vec<ModelInfo> = models
        .into_iter()
        .zip(model_metadata)
        .map(|(id, (capabilities, context_length))| ModelInfo {
            id,
            capabilities,
            context_length,
        })
        .collect();

    let brave_web_search = cfg.web_search_usable();
    let tool_selectors = tool_selectors(cfg, http).await;
    let image_generation = tool_selectors
        .iter()
        .any(|selector| selector.id == "image_generation");

    // Advertise research modes only when their required tools are usable. Each
    // preset declares concrete server tools (web_search only, today); a mode is
    // offered when every required tool is usable.
    let modes = cfg
        .presets()
        .all()
        .iter()
        .filter(|p| {
            p.tools
                .iter()
                .all(|t| tool_usable(t, brave_web_search, image_generation))
        })
        .map(|p| crate::state::ModeInfo {
            id: p.id.to_string(),
            label: p.label.to_string(),
            required_tools: p
                .tools
                .iter()
                .map(|t| tool_selector_id(t).unwrap_or(*t).to_string())
                .collect(),
        })
        .collect();

    CapabilitySnapshot {
        version: env!("CARGO_PKG_VERSION").to_string(),
        models,
        tool_selectors,
        modes,
    }
}

async fn tool_selectors(cfg: &Config, http: &reqwest::Client) -> Vec<ToolSelector> {
    let mut selectors = Vec::new();

    let mut information_tools = Vec::new();
    if cfg.web_search_usable() {
        information_tools.push("web_search".to_string());
    }
    if cfg.web_fetch_usable() {
        information_tools.push("web_fetch".to_string());
    }
    if cfg.calculator_usable() {
        information_tools.push("calculator".to_string());
    }
    if cfg.unit_convert_usable() {
        information_tools.push("unit_convert".to_string());
    }
    if cfg.weather_usable() {
        information_tools.push("weather".to_string());
    }
    if cfg.maps_places_usable() {
        information_tools.push("maps_places".to_string());
    }
    if cfg.market_data_usable() {
        information_tools.push("market_data".to_string());
    }
    if cfg.github_usable() {
        information_tools.push("github".to_string());
    }
    if cfg.ocr_usable() {
        information_tools.push("ocr".to_string());
    }
    if !information_tools.is_empty() {
        selectors.push(ToolSelector {
            id: "information".to_string(),
            label: "Information".to_string(),
            tools: information_tools,
        });
    }

    let comfy_reachable = probe_reachable(http, cfg.comfy_base.as_str(), "/system_stats").await;
    let mut image_tools = Vec::new();
    if comfy_reachable && cfg.image_gen_usable() {
        image_tools.push("image_generation".to_string());
    }
    if comfy_reachable && cfg.image_edit_usable() {
        image_tools.push("image_edit".to_string());
    }
    if !image_tools.is_empty() {
        selectors.push(ToolSelector {
            id: "image_generation".to_string(),
            label: "Images".to_string(),
            tools: image_tools,
        });
    }

    selectors
}

/// Whether a preset tool name maps to a currently usable server capability.
fn tool_usable(tool: &str, web_search: bool, image_generation: bool) -> bool {
    match tool {
        "web_search" => web_search,
        "image_generation" => image_generation,
        _ => false,
    }
}

fn tool_selector_id(tool: &str) -> Option<&'static str> {
    match tool {
        "web_search" => Some("information"),
        "image_generation" => Some("image_generation"),
        _ => None,
    }
}

/// Probe each model's `/api/show` metadata once (concurrent, best-effort, short
/// timeout). Capability field names mirror the upstream names (e.g.
/// `"completion"`, `"vision"`, `"tools"`, `"thinking"`).
async fn detect_model_metadata(
    client: &OllamaClient,
    models: &[String],
) -> Vec<(Option<ModelCapabilities>, Option<u64>)> {
    let checks = models.iter().map(|model| async move {
        match tokio::time::timeout(PROBE_TIMEOUT, client.model_metadata(model)).await {
            Ok(Ok(metadata)) => (
                Some(ModelCapabilities::from_names(&metadata.capabilities)),
                metadata.context_length,
            ),
            _ => (None, None),
        }
    });
    futures_util::future::join_all(checks).await
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
        UpstreamKind::OpenAICompatible => {
            UpstreamChatBackend::OpenAICompatible(OpenAICompatibleClient::new(
                http.clone(),
                &cfg.ollama_base,
                cfg.upstream_api_key.as_deref(),
            ))
        }
    };
    // Stand up the server-hosted image store when configured. A configured-but-
    // unwritable directory degrades to inline delivery (logged) rather than
    // taking down startup.
    let images = cfg.image_store_dir.as_ref().and_then(|dir| {
        match images::BlobStore::new(
            dir.clone(),
            &cfg.auth_token,
            cfg.image_store_ttl_s,
            cfg.comfy_max_image_bytes,
            cfg.public_base_url.as_ref(),
        ) {
            Ok(store) => {
                tracing::info!(dir = %dir.display(), "server-hosted image store enabled");
                Some(store)
            }
            Err(e) => {
                tracing::error!(dir = %dir.display(), error = %e,
                    "image store unavailable; falling back to inline image delivery");
                None
            }
        }
    });
    state::AppState {
        upstream_sem: Arc::new(tokio::sync::Semaphore::new(cfg.ollama_concurrency)),
        cfg,
        http,
        upstream,
        capabilities,
        continuations: state::ContinuationCache::new(),
        images,
    }
}
