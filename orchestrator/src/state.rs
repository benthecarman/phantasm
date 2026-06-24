//! Shared application state, cheaply cloneable (`Arc` internals).

use std::sync::Arc;

use serde::Serialize;
use tokio::sync::Semaphore;

use crate::config::Config;
use crate::ollama::OllamaClient;

#[derive(Clone)]
pub struct AppState {
    pub cfg: Arc<Config>,
    pub http: reqwest::Client,
    pub ollama: OllamaClient,
    /// Bounds simultaneous in-flight Ollama generations (NFR-O2 downstream limit).
    pub ollama_sem: Arc<Semaphore>,
    pub capabilities: Arc<CapabilitySnapshot>,
}

/// What `/v1/capabilities` reports — computed once at startup from config +
/// reachability probes.
#[derive(Debug, Clone, Serialize)]
pub struct CapabilitySnapshot {
    pub version: String,
    pub chat: bool,
    pub models: Vec<String>,
    pub tools: ToolFlags,
    pub streaming: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolFlags {
    pub web_search: bool,
    pub image_generation: bool,
}
