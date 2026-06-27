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

/// A `<node>.<key>` reference into an API-format ComfyUI workflow: which node ID
/// receives an injected input, and under which input key. Different workflows
/// expose the same logical input on different nodes/keys (e.g. seed lives on
/// `25.noise_seed` for FHDR but `7.seed` for Krea), so every injection target is
/// configured this way rather than hardcoded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeInput {
    pub node: String,
    pub key: String,
}

impl NodeInput {
    /// Parse `"<node>.<key>"` (e.g. `"25.noise_seed"`). Splits on the first `.`;
    /// node IDs are numeric and keys are identifiers, so there is no ambiguity.
    /// Returns `None` for blank or malformed values.
    pub fn parse(raw: &str) -> Option<NodeInput> {
        let (node, key) = raw.trim().split_once('.')?;
        if node.is_empty() || key.is_empty() {
            return None;
        }
        Some(NodeInput {
            node: node.to_string(),
            key: key.to_string(),
        })
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub bind_addr: SocketAddr,
    pub auth_token: String,
    /// Browser CORS allow-list. Empty => CORS disabled (no `Access-Control-*`
    /// headers, no preflight handling) — the default, since the iOS app is not a
    /// browser and needs none. A single `*` entry allows any origin; otherwise
    /// it's an exact-match list of origins (e.g. `https://chat.example`).
    pub cors_allowed_origins: Vec<String>,

    // Ollama (upstream model host)
    pub ollama_base: Url,
    pub upstream_api_key: Option<String>,
    pub default_model: String,
    /// Models advertised in /v1/capabilities. Empty => probe `/api/tags` at startup.
    pub models: Vec<String>,
    pub max_tool_iters: u8,
    pub ollama_concurrency: usize,

    // Request guards (DoS surface). The body limit is the coarse cap on the whole
    // request; the image caps are the finer ones — many small inline images, or a
    // single oversized one that still fits under the body limit.
    /// Max bytes accepted for an entire request body (`DefaultBodyLimit`).
    pub max_request_body_bytes: usize,
    /// Max number of inline images (attached `image_url` parts + `data:` URIs
    /// embedded in message text) accepted across one request's history.
    pub max_request_images: usize,
    /// Max decoded bytes accepted for a single inline image.
    pub max_request_image_bytes: usize,

    // Research mode presets. Mode ids/labels/tools are server-side data
    // (orchestrator::presets); these knobs override the per-tier numeric/boolean
    // defaults. Used by `PresetTable::from_config`. `research_fanout_concurrency`
    // bounds how many sub-questions run in parallel (stage 3 fan-out).
    pub research_deep_fanout: usize,
    pub research_deep_searches_per_subq: usize,
    pub research_deep_verify: bool,
    pub research_quick_fanout: usize,
    pub research_quick_searches_per_subq: usize,
    pub research_quick_verify: bool,
    pub research_fanout_concurrency: usize,

    // Web search tool (Brave)
    pub web_search_enabled: bool,
    pub brave_base: Url,
    pub brave_token: Option<String>,
    pub search_max_results: usize,
    pub search_context_char_cap: usize,
    /// Per-PAGE extract cap when fetching full pages (independent of result
    /// count) — stops the old `cap / results.len()` starvation that left each
    /// page with ~800 chars. A sub-agent reading one sub-question reads each
    /// page up to this many chars.
    pub search_page_chars: usize,
    /// Overall context cap for a *research* search turn. Larger than
    /// `search_context_char_cap` (which still bounds ordinary thorough searches)
    /// so a research sub-agent reading several pages for one sub-question is not
    /// starved.
    pub research_context_char_cap: usize,
    // Thorough (full-page-fetch) search: runtime gate + fetch bounds. The model
    // opts in per query via `depth="thorough"`; this only permits it.
    pub search_fetch_pages: bool,
    pub search_fetch_concurrency: usize,
    pub search_fetch_timeout_ms: u64,

    // General first-party tools. They are all stateless and disabled unless
    // explicitly enabled. API-key-backed tools additionally require their key
    // before their schema is offered to a model.
    pub tool_user_agent: String,
    pub web_fetch_enabled: bool,
    pub web_fetch_context_chars: usize,
    pub calculator_enabled: bool,
    pub unit_convert_enabled: bool,
    pub weather_enabled: bool,
    pub open_meteo_base: Url,
    pub open_meteo_geocoding_base: Url,
    pub maps_places_enabled: bool,
    pub nominatim_base: Url,
    pub overpass_base: Url,
    pub market_data_enabled: bool,
    pub alpha_vantage_base: Url,
    pub alpha_vantage_token: Option<String>,
    pub github_enabled: bool,
    pub github_base: Url,
    pub github_token: Option<String>,
    pub github_context_chars: usize,
    pub ocr_enabled: bool,
    pub ocr_timeout_s: u64,
    pub ocr_context_chars: usize,
    pub tesseract_bin: String,

    // Image tools (ComfyUI). Generation and editing are independent tools, each
    // backed by its own API-format workflow and gated by its own toggle.
    pub image_gen_enabled: bool,
    pub image_edit_enabled: bool,
    pub comfy_base: Url,
    pub comfy_timeout_s: u64,
    /// Max bytes accepted from ComfyUI's `/view` for a single image. Guards
    /// against a misconfigured/4K output stalling or bloating the turn.
    pub comfy_max_image_bytes: usize,

    // Server-hosted image blobs. When `image_store_dir` is set, generated/edited
    // images are persisted there and delivered to the app as signed URL
    // references (`/v1/images/<id>`) instead of inline base64 — keeping re-sent
    // history small. Unset => disabled, and images stay inline (back-compat).
    pub image_store_dir: Option<PathBuf>,
    /// How long a generated image is reachable (default 90 days): both the
    /// on-disk blob's lifetime (the pruner evicts past it) and the signed URL's
    /// expiry — one lifetime, since a link to a pruned blob is useless. The edit
    /// tool reads the blob directly when editing a referenced image, and it
    /// backstops app deletes that never arrive. The unguessable content-hash id
    /// is the primary access guard; the signature + expiry are defense-in-depth.
    pub image_store_ttl_s: u64,
    /// Public origin the app reaches this server at, used to mint absolute image
    /// URLs. Unset => emit site-relative `/v1/images/<id>` and let the app
    /// resolve against the base URL it already dials.
    pub public_base_url: Option<Url>,

    // Generation workflow + its input-node mappings (`<node>.<key>`).
    pub comfy_gen_workflow: Option<PathBuf>,
    pub comfy_gen_prompt: Option<NodeInput>,
    pub comfy_gen_negative: Option<NodeInput>,
    pub comfy_gen_width: Option<NodeInput>,
    pub comfy_gen_height: Option<NodeInput>,
    pub comfy_gen_seed: Option<NodeInput>,

    // Edit workflow + its input-node mappings. `comfy_edit_image` is the
    // `LoadImage` node that receives the user's uploaded image.
    pub comfy_edit_workflow: Option<PathBuf>,
    pub comfy_edit_prompt: Option<NodeInput>,
    pub comfy_edit_image: Option<NodeInput>,
    pub comfy_edit_seed: Option<NodeInput>,

    // Logging
    pub log_format: LogFormat,
    pub log_content: bool,

    /// Lazily-built, process-lifetime research preset table (built from the knobs
    /// above on first access via [`Config::presets`]). Internal cache: construct
    /// it empty (`Default::default()`) — never populate it directly.
    pub presets: std::sync::OnceLock<&'static crate::orchestrator::PresetTable>,
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
        let image_edit_enabled = env_bool("TOOL_IMAGE_EDIT", false);
        let comfy_base = parse_url("COMFYUI_BASE_URL", "http://localhost:8188")?;

        Ok(Config {
            bind_addr,
            auth_token,
            cors_allowed_origins: csv("PHANTASM_CORS_ALLOWED_ORIGINS"),
            ollama_base,
            upstream_api_key,
            default_model,
            models,
            max_tool_iters: env_parse("MAX_TOOL_ITERS", 5),
            ollama_concurrency: env_parse("OLLAMA_MAX_CONCURRENCY", 4usize).max(1),
            max_request_body_bytes: env_parse("MAX_REQUEST_BODY_BYTES", 32 * 1024 * 1024),
            max_request_images: env_parse("MAX_REQUEST_IMAGES", 16usize),
            max_request_image_bytes: env_parse("MAX_REQUEST_IMAGE_BYTES", 16 * 1024 * 1024),
            research_deep_fanout: env_parse("RESEARCH_DEEP_FANOUT", 4usize),
            research_deep_searches_per_subq: env_parse("RESEARCH_DEEP_SEARCHES_PER_SUBQ", 3usize),
            research_deep_verify: env_bool("RESEARCH_DEEP_VERIFY", true),
            research_quick_fanout: env_parse("RESEARCH_QUICK_FANOUT", 2usize),
            research_quick_searches_per_subq: env_parse("RESEARCH_QUICK_SEARCHES_PER_SUBQ", 2usize),
            research_quick_verify: env_bool("RESEARCH_QUICK_VERIFY", false),
            research_fanout_concurrency: env_parse("RESEARCH_FANOUT_CONCURRENCY", 2usize).max(1),
            web_search_enabled,
            brave_base,
            brave_token,
            search_max_results: env_parse("SEARCH_MAX_RESULTS", 5usize),
            search_context_char_cap: env_parse("SEARCH_CONTEXT_CHARS", 4000usize),
            search_page_chars: env_parse("SEARCH_PAGE_CHARS", 2500usize).max(200),
            research_context_char_cap: env_parse("RESEARCH_CONTEXT_CHARS", 12000usize),
            search_fetch_pages: env_bool("SEARCH_FETCH_PAGES", false),
            search_fetch_concurrency: env_parse("SEARCH_FETCH_CONCURRENCY", 3usize).max(1),
            search_fetch_timeout_ms: env_parse("SEARCH_FETCH_TIMEOUT_MS", 1500u64),
            tool_user_agent: env_or(
                "TOOL_HTTP_USER_AGENT",
                concat!("Phantasm/", env!("CARGO_PKG_VERSION"), " self-hosted"),
            ),
            web_fetch_enabled: env_bool("TOOL_WEB_FETCH", false),
            web_fetch_context_chars: env_parse("WEB_FETCH_CONTEXT_CHARS", 8000usize).max(500),
            calculator_enabled: env_bool("TOOL_CALCULATOR", false),
            unit_convert_enabled: env_bool("TOOL_UNIT_CONVERT", false),
            weather_enabled: env_bool("TOOL_WEATHER", false),
            open_meteo_base: parse_url("OPEN_METEO_BASE_URL", "https://api.open-meteo.com")?,
            open_meteo_geocoding_base: parse_url(
                "OPEN_METEO_GEOCODING_BASE_URL",
                "https://geocoding-api.open-meteo.com",
            )?,
            maps_places_enabled: env_bool("TOOL_MAPS_PLACES", false),
            nominatim_base: parse_url("NOMINATIM_BASE_URL", "https://nominatim.openstreetmap.org")?,
            overpass_base: parse_url("OVERPASS_BASE_URL", "https://overpass-api.de")?,
            market_data_enabled: env_bool("TOOL_MARKET_DATA", false),
            alpha_vantage_base: parse_url("ALPHA_VANTAGE_BASE_URL", "https://www.alphavantage.co")?,
            alpha_vantage_token: std::env::var("ALPHA_VANTAGE_API_KEY")
                .ok()
                .filter(|s| !s.trim().is_empty()),
            github_enabled: env_bool("TOOL_GITHUB", false),
            github_base: parse_url("GITHUB_API_BASE_URL", "https://api.github.com")?,
            github_token: std::env::var("GITHUB_TOKEN")
                .ok()
                .filter(|s| !s.trim().is_empty()),
            github_context_chars: env_parse("GITHUB_CONTEXT_CHARS", 8000usize).max(500),
            ocr_enabled: env_bool("TOOL_OCR", false),
            ocr_timeout_s: env_parse("OCR_TIMEOUT_S", 20u64),
            ocr_context_chars: env_parse("OCR_CONTEXT_CHARS", 8000usize).max(500),
            tesseract_bin: env_or("TESSERACT_BIN", "tesseract"),
            image_gen_enabled,
            image_edit_enabled,
            comfy_base,
            comfy_timeout_s: env_parse("COMFYUI_TIMEOUT_S", 120u64),
            comfy_max_image_bytes: env_parse("COMFYUI_MAX_IMAGE_BYTES", 16 * 1024 * 1024),
            image_store_dir: env_path("IMAGE_STORE_DIR"),
            image_store_ttl_s: env_parse("IMAGE_STORE_TTL_S", 90 * 24 * 60 * 60),
            public_base_url: parse_opt_url("PUBLIC_BASE_URL")?,
            comfy_gen_workflow: env_path("COMFYUI_GEN_WORKFLOW"),
            comfy_gen_prompt: env_node("COMFYUI_GEN_PROMPT"),
            comfy_gen_negative: env_node("COMFYUI_GEN_NEGATIVE"),
            comfy_gen_width: env_node("COMFYUI_GEN_WIDTH"),
            comfy_gen_height: env_node("COMFYUI_GEN_HEIGHT"),
            comfy_gen_seed: env_node("COMFYUI_GEN_SEED"),
            comfy_edit_workflow: env_path("COMFYUI_EDIT_WORKFLOW"),
            comfy_edit_prompt: env_node("COMFYUI_EDIT_PROMPT"),
            comfy_edit_image: env_node("COMFYUI_EDIT_IMAGE"),
            comfy_edit_seed: env_node("COMFYUI_EDIT_SEED"),
            log_format: if env_or("LOG_FORMAT", "text").eq_ignore_ascii_case("json") {
                LogFormat::Json
            } else {
                LogFormat::Text
            },
            log_content: env_bool("LOG_MESSAGE_CONTENT", false),
            presets: std::sync::OnceLock::new(),
        })
    }

    /// The research preset table for this deployment, built once from the
    /// `research_*` knobs and cached for the process lifetime. Used by the chat
    /// route to resolve a request model id into its base + optional preset, and
    /// to populate `capabilities.modes`.
    pub fn presets(&self) -> &'static crate::orchestrator::PresetTable {
        self.presets.get_or_init(|| {
            Box::leak(Box::new(crate::orchestrator::PresetTable::from_config(
                self,
            )))
        })
    }

    /// Whether the web-search tool can actually run (toggle on + key present).
    pub fn web_search_usable(&self) -> bool {
        self.web_search_enabled && self.brave_token.is_some()
    }

    /// Whether the model may request a `depth="thorough"` (full-page-fetch)
    /// search. Gated by the `SEARCH_FETCH_PAGES` runtime flag; when off, the
    /// `depth` parameter is never offered and every search stays snippet-only.
    pub fn search_thorough_usable(&self) -> bool {
        self.search_fetch_pages
    }

    pub fn web_fetch_usable(&self) -> bool {
        self.web_fetch_enabled
    }

    pub fn calculator_usable(&self) -> bool {
        self.calculator_enabled
    }

    pub fn unit_convert_usable(&self) -> bool {
        self.unit_convert_enabled
    }

    pub fn weather_usable(&self) -> bool {
        self.weather_enabled
    }

    pub fn maps_places_usable(&self) -> bool {
        self.maps_places_enabled
    }

    pub fn market_data_usable(&self) -> bool {
        self.market_data_enabled && self.alpha_vantage_token.is_some()
    }

    pub fn github_usable(&self) -> bool {
        self.github_enabled
    }

    pub fn ocr_usable(&self) -> bool {
        self.ocr_enabled
    }

    /// App-facing "information tools" group. The capabilities manifest exposes
    /// these as concrete tool names under one UI bucket; research-mode gating
    /// still checks real Brave search separately.
    pub fn information_tools_usable(&self) -> bool {
        self.web_search_usable()
            || self.web_fetch_usable()
            || self.calculator_usable()
            || self.unit_convert_usable()
            || self.weather_usable()
            || self.maps_places_usable()
            || self.market_data_usable()
            || self.github_usable()
            || self.ocr_usable()
    }

    /// Whether the image-generation tool can run: toggle on + a workflow and a
    /// prompt-injection node configured (without those it could never run).
    pub fn image_gen_usable(&self) -> bool {
        self.image_gen_enabled
            && self.comfy_gen_workflow.is_some()
            && self.comfy_gen_prompt.is_some()
    }

    /// Whether the image-edit tool can run: toggle on + workflow + prompt node +
    /// the `LoadImage` node that receives the user's uploaded image.
    pub fn image_edit_usable(&self) -> bool {
        self.image_edit_enabled
            && self.comfy_edit_workflow.is_some()
            && self.comfy_edit_prompt.is_some()
            && self.comfy_edit_image.is_some()
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

fn env_path(key: &str) -> Option<PathBuf> {
    std::env::var(key)
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
}

fn env_node(key: &str) -> Option<NodeInput> {
    std::env::var(key).ok().and_then(|v| NodeInput::parse(&v))
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

/// Parse an optional URL env var: absent/blank => `None`; present-but-invalid is
/// a hard startup error rather than a silent fallback.
fn parse_opt_url(key: &str) -> Result<Option<Url>> {
    match std::env::var(key).ok().filter(|s| !s.trim().is_empty()) {
        Some(raw) => {
            Ok(Some(Url::parse(&raw).with_context(|| {
                format!("{key} must be a valid URL (got {raw:?})")
            })?))
        }
        None => Ok(None),
    }
}

#[cfg(test)]
pub mod tests_support {
    use super::*;

    /// A minimal in-memory config for unit tests (no env, no I/O).
    pub fn minimal() -> Config {
        Config {
            bind_addr: "0.0.0.0:0".parse().unwrap(),
            auth_token: "test-token".into(),
            cors_allowed_origins: vec![],
            ollama_base: "http://localhost:11434".parse().unwrap(),
            upstream_api_key: None,
            default_model: "m".into(),
            models: vec![],
            max_tool_iters: 5,
            ollama_concurrency: 4,
            max_request_body_bytes: 32 * 1024 * 1024,
            max_request_images: 16,
            max_request_image_bytes: 16 * 1024 * 1024,
            research_deep_fanout: 4,
            research_deep_searches_per_subq: 3,
            research_deep_verify: true,
            research_quick_fanout: 2,
            research_quick_searches_per_subq: 2,
            research_quick_verify: false,
            research_fanout_concurrency: 2,
            web_search_enabled: false,
            brave_base: "https://api.search.brave.com".parse().unwrap(),
            brave_token: None,
            search_max_results: 5,
            search_context_char_cap: 4000,
            search_page_chars: 2500,
            research_context_char_cap: 12000,
            search_fetch_pages: false,
            search_fetch_concurrency: 3,
            search_fetch_timeout_ms: 1500,
            tool_user_agent: "Phantasm/test".into(),
            web_fetch_enabled: false,
            web_fetch_context_chars: 8000,
            calculator_enabled: false,
            unit_convert_enabled: false,
            weather_enabled: false,
            open_meteo_base: "https://api.open-meteo.com".parse().unwrap(),
            open_meteo_geocoding_base: "https://geocoding-api.open-meteo.com".parse().unwrap(),
            maps_places_enabled: false,
            nominatim_base: "https://nominatim.openstreetmap.org".parse().unwrap(),
            overpass_base: "https://overpass-api.de".parse().unwrap(),
            market_data_enabled: false,
            alpha_vantage_base: "https://www.alphavantage.co".parse().unwrap(),
            alpha_vantage_token: None,
            github_enabled: false,
            github_base: "https://api.github.com".parse().unwrap(),
            github_token: None,
            github_context_chars: 8000,
            ocr_enabled: false,
            ocr_timeout_s: 20,
            ocr_context_chars: 8000,
            tesseract_bin: "tesseract".into(),
            image_gen_enabled: false,
            image_edit_enabled: false,
            comfy_base: "http://localhost:8188".parse().unwrap(),
            comfy_timeout_s: 120,
            comfy_max_image_bytes: 16 * 1024 * 1024,
            image_store_dir: None,
            image_store_ttl_s: 7 * 24 * 60 * 60,
            public_base_url: None,
            comfy_gen_workflow: None,
            comfy_gen_prompt: None,
            comfy_gen_negative: None,
            comfy_gen_width: None,
            comfy_gen_height: None,
            comfy_gen_seed: None,
            comfy_edit_workflow: None,
            comfy_edit_prompt: None,
            comfy_edit_image: None,
            comfy_edit_seed: None,
            log_format: LogFormat::Text,
            log_content: false,
            presets: std::sync::OnceLock::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::NodeInput;

    #[test]
    fn node_input_parses_node_and_key() {
        let n = NodeInput::parse("25.noise_seed").unwrap();
        assert_eq!(n.node, "25");
        assert_eq!(n.key, "noise_seed");
        // Only the first dot splits; keys never contain one but be explicit.
        assert_eq!(NodeInput::parse(" 6.text ").unwrap().key, "text");
    }

    #[test]
    fn node_input_rejects_blank_or_malformed() {
        assert!(NodeInput::parse("").is_none());
        assert!(NodeInput::parse("6").is_none());
        assert!(NodeInput::parse(".text").is_none());
        assert!(NodeInput::parse("6.").is_none());
    }
}
