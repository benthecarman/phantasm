//! Phantasm orchestrator library surface.
//!
//! Exposed so integration tests (and `main`) can build the router and bootstrap
//! helpers. See `routes::router` for the HTTP surface.

pub mod auth;
pub mod config;
pub mod error;
pub mod host_stats;
pub mod image_norm;
pub mod images;
pub mod metrics;
pub mod metrics_store;
pub mod net_guard;
pub mod ollama;
pub mod openai;
pub mod orchestrator;
pub mod routes;
pub mod state;
pub mod tools;
pub mod turn_registry;
pub mod upstreams;

use std::sync::Arc;
use std::time::Duration;

use tracing::warn;

use crate::config::{Config, UpstreamSpec};
use crate::ollama::{UpstreamChatBackend, UpstreamKind};
use crate::state::{CapabilitySnapshot, ModelCapabilities, ModelInfo, ToolSelector};
use crate::upstreams::{UpstreamEntry, UpstreamSet};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const UPSTREAM_READ_TIMEOUT: Duration = Duration::from_secs(120);
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Detect every configured upstream (the default `UPSTREAM_*` one plus each
/// `UPSTREAMS` extra) and return them as a routing-ready [`UpstreamSet`].
/// Upstreams are probed concurrently, so startup pays for the slowest host
/// rather than the sum. Detection failures are per-upstream and non-fatal: an
/// unreachable upstream keeps its configured (or empty) model list and simply
/// routes nothing until a later capabilities re-probe finds it up.
pub async fn detect_upstreams(cfg: &Config, http: &reqwest::Client) -> UpstreamSet {
    let specs = cfg.upstream_specs();
    let detections =
        futures_util::future::join_all(specs.iter().map(|spec| detect_one(spec, http))).await;
    let entries = specs
        .iter()
        .zip(detections)
        .map(|(spec, (kind, models, backend))| entry_from_spec(spec, cfg, kind, backend, models))
        .collect();
    UpstreamSet::new(entries)
}

/// Build the routing entry for one configured upstream. The single owner of
/// the per-upstream concurrency resolution (spec override, else the global
/// default, floored at 1) — keep [`detect_upstreams`] and [`build_state`] on
/// this path so they can't diverge.
fn entry_from_spec(
    spec: &UpstreamSpec,
    cfg: &Config,
    kind: UpstreamKind,
    backend: UpstreamChatBackend,
    probed_models: Vec<String>,
) -> UpstreamEntry {
    UpstreamEntry::new(
        spec.name.clone(),
        kind,
        spec.base.clone(),
        backend,
        spec.concurrency.unwrap_or(cfg.upstream_concurrency).max(1),
        spec.models.clone(),
        probed_models,
    )
}

/// Detect which upstream chat API one configured host exposes.
///
/// Native Ollama is preferred because it has the tool-call behavior this
/// orchestrator was built around. If the spec's kind is unset/`auto` and
/// `/api/tags` is unavailable, fall back to OpenAI-compatible `/v1/models`.
async fn detect_one(
    spec: &UpstreamSpec,
    http: &reqwest::Client,
) -> (UpstreamKind, Vec<String>, UpstreamChatBackend) {
    if let Some(kind) = spec.kind {
        let backend = UpstreamChatBackend::from_spec(kind, http.clone(), spec);
        let models = probe_backend_models(&backend).await.unwrap_or_else(|| {
            warn!(
                upstream = %spec.name,
                kind = ?kind,
                "could not list configured upstream models; continuing with configured model list"
            );
            Vec::new()
        });
        return (kind, models, backend);
    }

    let native = UpstreamChatBackend::from_spec(UpstreamKind::NativeOllama, http.clone(), spec);
    if let Some(models) = probe_backend_models(&native).await {
        return (UpstreamKind::NativeOllama, models, native);
    }

    let openai = UpstreamChatBackend::from_spec(UpstreamKind::OpenAICompatible, http.clone(), spec);
    if let Some(models) = probe_backend_models(&openai).await {
        return (UpstreamKind::OpenAICompatible, models, openai);
    }

    warn!(upstream = %spec.name, "could not detect upstream type; defaulting to native Ollama mode");
    let backend = UpstreamChatBackend::from_spec(UpstreamKind::NativeOllama, http.clone(), spec);
    (UpstreamKind::NativeOllama, Vec::new(), backend)
}

async fn probe_backend_models(backend: &UpstreamChatBackend) -> Option<Vec<String>> {
    tokio::time::timeout(PROBE_TIMEOUT, backend.list_models())
        .await
        .ok()
        .and_then(Result::ok)
}

/// Compute the capabilities manifest from config + bounded startup probes (FR-O1).
///
/// With several upstreams the advertised model list is the union of every
/// upstream's models, deduped by [`UpstreamSet::claimed_models`] — the same
/// precedence as [`UpstreamSet::route`], so what is advertised is what routes.
/// Each successful re-probe also refreshes the entry's routing model list.
/// `reuse_probed` skips re-listing and trusts each entry's current list — used
/// at startup, right after detection already probed every upstream. Probes run
/// concurrently across upstreams so one slow/down host doesn't stall the rest
/// (this path blocks `/v1/models` requests on capability-TTL expiry).
pub async fn probe_capabilities(
    cfg: &Config,
    http: &reqwest::Client,
    upstreams: &UpstreamSet,
    reuse_probed: bool,
) -> CapabilitySnapshot {
    // Refresh every non-pinned entry's routing model list, concurrently.
    if !reuse_probed {
        futures_util::future::join_all(
            upstreams
                .entries()
                .iter()
                .filter(|entry| !entry.pinned())
                .map(|entry| async move {
                    if let Some(fresh) = probe_backend_models(&entry.backend).await {
                        entry.set_probed_models(fresh);
                    } else {
                        // A transiently unreachable upstream keeps its last-known
                        // list so routing (and the advertised set) doesn't flap
                        // with one bad probe.
                        warn!(upstream = %entry.name, "could not list upstream models; keeping last-known list");
                    }
                }),
        )
        .await;
    }

    // Per-model vision + tool support is only knowable for native Ollama (via
    // `/api/show`). For an OpenAI-compatible upstream we omit model
    // capabilities so clients can distinguish unknown from known-unsupported.
    let claimed = upstreams.claimed_models();
    let per_entry = futures_util::future::join_all(upstreams.entries().iter().zip(&claimed).map(
        |(entry, ids)| async move {
            let metadata = match entry.kind {
                UpstreamKind::NativeOllama => detect_model_metadata(&entry.backend, ids).await,
                UpstreamKind::OpenAICompatible => vec![(None, None); ids.len()],
            };
            ids.iter().cloned().zip(metadata).collect::<Vec<_>>()
        },
    ))
    .await;
    let models: Vec<ModelInfo> = per_entry
        .into_iter()
        .flatten()
        .map(|(id, (capabilities, context_length))| ModelInfo {
            id,
            capabilities,
            context_length,
        })
        .collect();
    if models.is_empty() {
        warn!("no upstream reported any models; advertising none");
    }

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
/// network; `utilities` groups the offline, on-box tools (calculator, time, unit
/// conversion, local OCR) — the app offers those unconditionally, so toggling
/// web access off never disables them.
fn offline_tool_selectors(cfg: &Config) -> Vec<ToolSelector> {
    let mut selectors = Vec::new();
    let code_exec_deployable = cfg.code_exec_usable()
        && crate::tools::code_exec_pool::deployment_preflight(cfg)
            .map_err(|e| tracing::warn!(error = %e, "code-exec unavailable for capabilities"))
            .is_ok();
    if let Some(web) = make_selector(
        "web_search",
        "Web access",
        &[
            (cfg.web_search_usable(), "web_search"),
            (cfg.web_fetch_usable(), "web_fetch"),
            (cfg.weather_usable(), "weather"),
            (cfg.sports_usable(), "sports"),
            (cfg.maps_places_usable(), "maps_places"),
            (cfg.market_data_usable(), "market_data"),
            (cfg.github_usable(), "github"),
            // `code_exec` appears in BOTH this bucket and utilities (same name). It
            // is always available (via utilities); listing it here too means that
            // when web access is on, its run gets internet — the server reads the
            // web-access signal from the other tools in this bucket, not the name.
            (code_exec_deployable, "code_exec"),
        ],
    ) {
        selectors.push(web);
    }
    if let Some(utilities) = make_selector(
        "utilities",
        "Utilities",
        &[
            (cfg.calculator_usable(), "calculator"),
            (cfg.time_usable(), "time"),
            (cfg.unit_convert_usable(), "unit_convert"),
            (cfg.ocr_usable(), "ocr"),
            // Always-on like the other utilities; with web access off it runs with
            // no network at all (so it carries no web risk).
            (code_exec_deployable, "code_exec"),
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
        "web_search" | "web_fetch" | "weather" | "sports" | "maps_places" | "market_data"
        | "github" => Some("web_search"),
        // `code_exec` lives in both utilities and web_search; report its always-on
        // home (utilities) for mode-requirement resolution.
        "calculator" | "time" | "unit_convert" | "ocr" | "code_exec" => Some("utilities"),
        "image_generation" | "image_edit" => Some("image_generation"),
        _ => None,
    }
}

/// Probe each model's `/api/show` metadata once (concurrent, best-effort, short
/// timeout). Capability field names mirror the upstream names (e.g.
/// `"completion"`, `"vision"`, `"tools"`, `"thinking"`).
async fn detect_model_metadata(
    upstream: &UpstreamChatBackend,
    models: &[String],
) -> Vec<(Option<ModelCapabilities>, Option<u64>)> {
    let checks = models.iter().map(|model| async move {
        match tokio::time::timeout(PROBE_TIMEOUT, upstream.model_metadata(model)).await {
            Ok(Some(Ok(metadata))) => (
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

/// HTTP client used for upstream calls. Per-read timeout lets streaming responses
/// run indefinitely as long as bytes keep arriving, while stalled backends release
/// their turn.
pub fn build_http_client() -> Result<reqwest::Client, reqwest::Error> {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .read_timeout(UPSTREAM_READ_TIMEOUT)
        .build()
}

/// Build `AppState` from a loaded config and explicit upstream kind for the
/// upstreams (no auto-detection). Kept for tests that force one provider;
/// production should use the set returned by [`detect_upstreams`] via
/// [`build_state_with_upstreams`].
pub fn build_state(
    cfg: Arc<Config>,
    capabilities: Arc<CapabilitySnapshot>,
    upstream_kind: UpstreamKind,
) -> state::AppState {
    let http = build_http_client().expect("building HTTP client");
    let entries = cfg
        .upstream_specs()
        .iter()
        .map(|spec| {
            let kind = spec.kind.unwrap_or(upstream_kind);
            let backend = UpstreamChatBackend::from_spec(kind, http.clone(), spec);
            entry_from_spec(spec, &cfg, kind, backend, Vec::new())
        })
        .collect();
    build_state_with_upstreams(cfg, capabilities, http, UpstreamSet::new(entries))
}

/// Build `AppState` using already-detected upstream backends. This keeps
/// startup detection, chat, warm, and capability refreshes pinned to one
/// provider kind per upstream unless the process is restarted with different
/// config.
pub fn build_state_with_upstreams(
    cfg: Arc<Config>,
    capabilities: Arc<CapabilitySnapshot>,
    http: reqwest::Client,
    mut upstreams: UpstreamSet,
) -> state::AppState {
    let capabilities = state::CapabilitiesCache::new(capabilities);
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
    let turns = turn_registry::TurnRegistry::new(
        Duration::from_secs(cfg.turn_result_ttl_s),
        cfg.turn_registry_max,
    );
    // Background maintenance: evict result-TTL-expired finished turns, and cancel
    // turns left running with no client (a force-killed app) so they don't hold
    // the GPU. Abandoned-turn cancellation is disabled when the grace is 0; TTL
    // eviction always runs. Tick at most once a minute (more often for a short
    // grace), and never zero.
    let abandon_grace = Duration::from_secs(cfg.turn_abandon_grace_s);
    let tick = match abandon_grace {
        Duration::ZERO => Duration::from_secs(60),
        g => g.min(Duration::from_secs(60)),
    };
    turns.spawn_watchdog(abandon_grace, tick);
    // Durable metrics history for the dashboard. An unopenable database
    // degrades to memory-only metrics (`/metrics` still works) — storage is
    // never fatal.
    let store = cfg.metrics_db.as_ref().and_then(|path| {
        match metrics_store::spawn(path.clone(), cfg.metrics_retention_days) {
            Ok(handle) => {
                tracing::info!(db = %path.display(), "metrics store enabled");
                Some(handle)
            }
            Err(e) => {
                tracing::warn!(db = %path.display(), error = %e,
                    "metrics store unavailable; falling back to memory-only metrics");
                None
            }
        }
    });
    let metrics = metrics::Metrics::new(store);
    upstreams.attach_metrics(metrics.clone());
    state::AppState {
        cfg,
        http,
        upstreams: Arc::new(upstreams),
        capabilities,
        continuations: state::ContinuationCache::new(),
        turns,
        images,
        code_exec,
        metrics,
    }
}

#[cfg(test)]
mod tests {
    use super::{make_selector, offline_tool_selectors, tool_selector_id};

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
        for tool in ["calculator", "time", "unit_convert", "ocr", "code_exec"] {
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

    #[test]
    fn code_exec_is_not_advertised_when_preflight_fails() {
        let mut cfg = crate::config::tests_support::minimal();
        cfg.code_exec_enabled = true;
        cfg.code_exec_network = None;

        let selectors = offline_tool_selectors(&cfg);
        assert!(
            selectors
                .iter()
                .flat_map(|selector| selector.tools.iter())
                .all(|tool| tool != "code_exec"),
            "code_exec must fail closed when deployment preflight fails"
        );
    }
}
