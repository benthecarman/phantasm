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
use crate::ollama::OllamaClient;
use crate::state::{CapabilitySnapshot, ToolFlags};

/// Compute the capabilities manifest from config + bounded startup probes (FR-O1).
pub async fn probe_capabilities(
    cfg: &Config,
    ollama: &OllamaClient,
    http: &reqwest::Client,
) -> CapabilitySnapshot {
    let models = if !cfg.models.is_empty() {
        cfg.models.clone()
    } else {
        match tokio::time::timeout(Duration::from_secs(2), ollama.list_models()).await {
            Ok(Ok(m)) => m,
            _ => {
                warn!("could not list Ollama models at startup; advertising none");
                Vec::new()
            }
        }
    };

    let web_search = cfg.web_search_usable();
    let image_generation = cfg.image_gen_usable()
        && probe_reachable(http, cfg.comfy_base.as_str(), "/system_stats").await;

    CapabilitySnapshot {
        version: env!("CARGO_PKG_VERSION").to_string(),
        chat: true,
        models,
        tools: ToolFlags {
            web_search,
            image_generation,
        },
        streaming: "sse",
    }
}

/// Cheap reachability check with a short timeout; failures are non-fatal.
pub async fn probe_reachable(http: &reqwest::Client, base: &str, path: &str) -> bool {
    let url = format!("{}{}", base.trim_end_matches('/'), path);
    matches!(
        tokio::time::timeout(Duration::from_secs(2), http.get(url).send()).await,
        Ok(Ok(resp)) if resp.status().is_success()
    )
}

/// Build `AppState` from a loaded config (shared by `main` and tests).
pub fn build_state(cfg: Arc<Config>, capabilities: Arc<CapabilitySnapshot>) -> state::AppState {
    let http = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .build()
        .expect("building HTTP client");
    let ollama = OllamaClient::new(http.clone(), cfg.ollama_base.clone());
    state::AppState {
        ollama_sem: Arc::new(tokio::sync::Semaphore::new(cfg.ollama_concurrency)),
        cfg,
        http,
        ollama,
        capabilities,
    }
}
