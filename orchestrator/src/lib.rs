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
    let mut selectors = offline_tool_selectors(cfg);
    let comfy_reachable = probe_reachable(http, cfg.comfy_base.as_str(), "/system_stats").await;
    if comfy_reachable {
        if let Some(images) = make_selector(
            "image_generation",
            "Images",
            &[
                (cfg.image_gen_usable(), "image_generation"),
                (cfg.image_edit_usable(), "image_edit"),
            ],
        ) {
            selectors.push(images);
        }
    }
    selectors
}

/// The selectors derivable from config alone (everything except images, which
/// also needs a reachable ComfyUI). Split out so the bucketing is unit-testable
/// without a network probe.
///
/// `web_search` groups the tools that reach out to third parties over the
/// network; `utilities` groups the offline, on-box tools (calculator, unit
/// conversion, local OCR) — the app offers those unconditionally, so toggling
/// web access off never disables them.
fn offline_tool_selectors(cfg: &Config) -> Vec<ToolSelector> {
    let mut selectors = Vec::new();
    if let Some(web) = make_selector(
        "web_search",
        "Web access",
        &[
            (cfg.web_search_usable(), "web_search"),
            (cfg.web_fetch_usable(), "web_fetch"),
            (cfg.weather_usable(), "weather"),
            (cfg.maps_places_usable(), "maps_places"),
            (cfg.market_data_usable(), "market_data"),
            (cfg.github_usable(), "github"),
            // `code_exec` appears in BOTH this bucket and utilities (same name). It
            // is always available (via utilities); listing it here too means that
            // when web access is on, its run gets internet — the server reads the
            // web-access signal from the other tools in this bucket, not the name.
            (cfg.code_exec_usable(), "code_exec"),
        ],
    ) {
        selectors.push(web);
    }
    if let Some(utilities) = make_selector(
        "utilities",
        "Utilities",
        &[
            (cfg.calculator_usable(), "calculator"),
            (cfg.unit_convert_usable(), "unit_convert"),
            (cfg.ocr_usable(), "ocr"),
            // Always-on like the other utilities; with web access off it runs with
            // no network at all (so it carries no web risk).
            (cfg.code_exec_usable(), "code_exec"),
        ],
    ) {
        selectors.push(utilities);
    }
    selectors
}

/// Build a selector from its usable tools, or `None` when none are usable (so an
/// empty bucket is never advertised).
fn make_selector(id: &str, label: &str, candidates: &[(bool, &str)]) -> Option<ToolSelector> {
    let tools: Vec<String> = candidates
        .iter()
        .filter(|(usable, _)| *usable)
        .map(|(_, name)| name.to_string())
        .collect();
    (!tools.is_empty()).then(|| ToolSelector {
        id: id.to_string(),
        label: label.to_string(),
        tools,
    })
}

/// Whether a preset tool name maps to a currently usable server capability.
fn tool_usable(tool: &str, web_search: bool, image_generation: bool) -> bool {
    match tool {
        "web_search" => web_search,
        "image_generation" => image_generation,
        _ => false,
    }
}

/// The app-facing selector id that gates a concrete server tool, mirroring the
/// buckets built in `tool_selectors`. Used to translate a preset's concrete tool
/// needs into the selector ids a mode requires.
fn tool_selector_id(tool: &str) -> Option<&'static str> {
    match tool {
        "web_search" | "web_fetch" | "weather" | "maps_places" | "market_data" | "github" => {
            Some("web_search")
        }
        // `code_exec` lives in both utilities and web_search; report its always-on
        // home (utilities) for mode-requirement resolution.
        "calculator" | "unit_convert" | "ocr" | "code_exec" => Some("utilities"),
        "image_generation" | "image_edit" => Some("image_generation"),
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
    // taking down startup. The signed-URL HMAC key is the auth token when one is
    // set; with auth disabled there's no token, so derive a random per-process
    // key (blobs are ephemeral, so a key that resets on restart is fine).
    let image_signing_key = cfg
        .auth_token
        .clone()
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let images = cfg.image_store_dir.as_ref().and_then(|dir| {
        match images::BlobStore::new(
            dir.clone(),
            &image_signing_key,
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
    // Stand up the code-exec warm pool when the tool is enabled. A failure to
    // construct it (e.g. an empty runtime) disables the tool rather than taking
    // down startup; warm-up itself runs in the background and degrades to cold
    // fallback, so this never blocks boot on container launches.
    let code_exec = if cfg.code_exec_usable() {
        match crate::tools::code_exec_pool::CodeExecPools::new(cfg.clone()) {
            Ok(pools) => {
                tracing::info!(
                    runtime = %cfg.code_exec_runtime,
                    pool_size = cfg.code_exec_pool_size,
                    "code execution tools enabled (offline + online lanes)"
                );
                Some(pools)
            }
            Err(e) => {
                tracing::error!(error = %e, "code-exec pools unavailable; tool disabled");
                None
            }
        }
    } else {
        None
    };
    state::AppState {
        upstream_sem: Arc::new(tokio::sync::Semaphore::new(cfg.ollama_concurrency)),
        cfg,
        http,
        upstream,
        capabilities,
        continuations: state::ContinuationCache::new(),
        images,
        code_exec,
    }
}

#[cfg(test)]
mod tests {
    use super::{make_selector, tool_selector_id};

    #[test]
    fn tool_selector_id_groups_network_and_local_tools() {
        // Outbound-to-the-internet tools ride the web-search toggle.
        for tool in [
            "web_search",
            "web_fetch",
            "weather",
            "maps_places",
            "market_data",
            "github",
        ] {
            assert_eq!(
                tool_selector_id(tool),
                Some("web_search"),
                "{tool} should gate under web_search"
            );
        }
        // Offline tools live in their own always-on bucket. `code_exec` reports
        // utilities (its always-on home) even though it also appears in web_search.
        for tool in ["calculator", "unit_convert", "ocr", "code_exec"] {
            assert_eq!(
                tool_selector_id(tool),
                Some("utilities"),
                "{tool} should gate under utilities"
            );
        }
        for tool in ["image_generation", "image_edit"] {
            assert_eq!(tool_selector_id(tool), Some("image_generation"));
        }
        assert_eq!(tool_selector_id("nonexistent"), None);
    }

    #[test]
    fn make_selector_keeps_usable_tools_and_drops_empty_buckets() {
        let selector = make_selector(
            "web_search",
            "Web search",
            &[(true, "web_search"), (false, "weather"), (true, "github")],
        )
        .expect("a bucket with usable tools is advertised");
        assert_eq!(selector.id, "web_search");
        assert_eq!(selector.tools, vec!["web_search", "github"]);

        assert!(
            make_selector("utilities", "Utilities", &[(false, "calculator")]).is_none(),
            "a bucket with no usable tools is not advertised"
        );
    }
}
