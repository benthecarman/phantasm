//! Runtime configuration, loaded entirely from environment variables (NFR-O4).
//!
//! `Config::from_env` fails fast at startup if a required variable is missing,
//! so a misconfigured deployment never silently serves a broken endpoint.

use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};
use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogFormat {
    Json,
    Text,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub bind_addr: SocketAddr,
    pub auth_token: String,

    // Ollama (upstream model host)
    pub ollama_base: Url,
    pub upstream_api_key: Option<String>,
    pub default_model: String,
    /// Models advertised in /v1/capabilities. Empty => probe `/api/tags` at startup.
    pub models: Vec<String>,
    pub max_tool_iters: u8,
    pub ollama_concurrency: usize,

    // Web search tool (Brave)
    pub web_search_enabled: bool,
    pub brave_base: Url,
    pub brave_token: Option<String>,
    pub search_max_results: usize,
    pub search_context_char_cap: usize,
    // Read only when the `page_fetch` feature is compiled in.
    #[cfg_attr(not(feature = "page_fetch"), allow(dead_code))]
    pub search_fetch_pages: bool,
    #[cfg_attr(not(feature = "page_fetch"), allow(dead_code))]
    pub search_fetch_concurrency: usize,
    #[cfg_attr(not(feature = "page_fetch"), allow(dead_code))]
    pub search_fetch_timeout_ms: u64,

    // Image generation tool (ComfyUI)
    pub image_gen_enabled: bool,
    pub comfy_base: Url,
    pub comfy_workflow_path: Option<PathBuf>,
    pub comfy_prompt_node: String,
    pub comfy_negative_node: Option<String>,
    pub comfy_seed_node: Option<String>,
    pub comfy_timeout_s: u64,

    // Logging
    pub log_format: LogFormat,
    pub log_content: bool,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let bind_addr = env_or("PHANTASM_BIND", "0.0.0.0:8080")
            .parse()
            .context("PHANTASM_BIND must be a socket address like 0.0.0.0:8080")?;

        let auth_token = std::env::var("PHANTASM_AUTH_TOKEN")
            .map_err(|_| anyhow!("PHANTASM_AUTH_TOKEN is required"))?;
        if auth_token.trim().is_empty() {
            return Err(anyhow!("PHANTASM_AUTH_TOKEN must not be empty"));
        }

        let ollama_base = parse_url("OLLAMA_BASE_URL", "http://localhost:11434")?;
        let upstream_api_key = std::env::var("UPSTREAM_API_KEY")
            .ok()
            .filter(|s| !s.trim().is_empty());
        let default_model = env_or("OLLAMA_DEFAULT_MODEL", "llama3.1");
        let models = csv("OLLAMA_MODELS");

        let web_search_enabled = env_bool("TOOL_WEB_SEARCH", false);
        let brave_base = parse_url("BRAVE_BASE_URL", "https://api.search.brave.com")?;
        let brave_token = std::env::var("BRAVE_API_KEY")
            .ok()
            .filter(|s| !s.is_empty());

        let image_gen_enabled = env_bool("TOOL_IMAGE_GEN", false);
        let comfy_base = parse_url("COMFYUI_BASE_URL", "http://localhost:8188")?;
        let comfy_workflow_path = std::env::var("COMFYUI_WORKFLOW_JSON")
            .ok()
            .map(PathBuf::from);

        Ok(Config {
            bind_addr,
            auth_token,
            ollama_base,
            upstream_api_key,
            default_model,
            models,
            max_tool_iters: env_parse("MAX_TOOL_ITERS", 5),
            ollama_concurrency: env_parse("OLLAMA_MAX_CONCURRENCY", 4usize).max(1),
            web_search_enabled,
            brave_base,
            brave_token,
            search_max_results: env_parse("SEARCH_MAX_RESULTS", 5usize),
            search_context_char_cap: env_parse("SEARCH_CONTEXT_CHARS", 4000usize),
            search_fetch_pages: env_bool("SEARCH_FETCH_PAGES", false),
            search_fetch_concurrency: env_parse("SEARCH_FETCH_CONCURRENCY", 3usize).max(1),
            search_fetch_timeout_ms: env_parse("SEARCH_FETCH_TIMEOUT_MS", 1500u64),
            image_gen_enabled,
            comfy_base,
            comfy_workflow_path,
            comfy_prompt_node: env_or("COMFYUI_PROMPT_NODE", "6"),
            comfy_negative_node: std::env::var("COMFYUI_NEGATIVE_NODE")
                .ok()
                .filter(|s| !s.is_empty()),
            comfy_seed_node: std::env::var("COMFYUI_SEED_NODE")
                .ok()
                .filter(|s| !s.is_empty()),
            comfy_timeout_s: env_parse("COMFYUI_TIMEOUT_S", 120u64),
            log_format: if env_or("LOG_FORMAT", "text").eq_ignore_ascii_case("json") {
                LogFormat::Json
            } else {
                LogFormat::Text
            },
            log_content: env_bool("LOG_MESSAGE_CONTENT", false),
        })
    }

    /// Whether the web-search tool can actually run (toggle on + key present).
    pub fn web_search_usable(&self) -> bool {
        self.web_search_enabled && self.brave_token.is_some()
    }

    /// Whether the image-gen tool can actually run (toggle on + a workflow configured).
    pub fn image_gen_usable(&self) -> bool {
        self.image_gen_enabled && self.comfy_workflow_path.is_some()
    }
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_bool(key: &str, default: bool) -> bool {
    match std::env::var(key) {
        Ok(v) => matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        Err(_) => default,
    }
}

fn env_parse<T: std::str::FromStr>(key: &str, default: T) -> T {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn csv(key: &str) -> Vec<String> {
    std::env::var(key)
        .ok()
        .map(|v| {
            v.split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn parse_url(key: &str, default: &str) -> Result<Url> {
    let raw = env_or(key, default);
    Url::parse(&raw).with_context(|| format!("{key} must be a valid URL (got {raw:?})"))
}

#[cfg(test)]
pub mod tests_support {
    use super::*;

    /// A minimal in-memory config for unit tests (no env, no I/O).
    pub fn minimal() -> Config {
        Config {
            bind_addr: "0.0.0.0:0".parse().unwrap(),
            auth_token: "test-token".into(),
            ollama_base: "http://localhost:11434".parse().unwrap(),
            upstream_api_key: None,
            default_model: "m".into(),
            models: vec![],
            max_tool_iters: 5,
            ollama_concurrency: 4,
            web_search_enabled: false,
            brave_base: "https://api.search.brave.com".parse().unwrap(),
            brave_token: None,
            search_max_results: 5,
            search_context_char_cap: 4000,
            search_fetch_pages: false,
            search_fetch_concurrency: 3,
            search_fetch_timeout_ms: 1500,
            image_gen_enabled: false,
            comfy_base: "http://localhost:8188".parse().unwrap(),
            comfy_workflow_path: None,
            comfy_prompt_node: "6".into(),
            comfy_negative_node: None,
            comfy_seed_node: None,
            comfy_timeout_s: 120,
            log_format: LogFormat::Text,
            log_content: false,
        }
    }
}
