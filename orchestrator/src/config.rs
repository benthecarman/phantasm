//! Runtime configuration, loaded entirely from environment variables (NFR-O4).
//!
//! `Config::from_env` fails fast at startup if a required variable is missing,
//! so a misconfigured deployment never silently serves a broken endpoint.

use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};
use url::Url;

use crate::ollama::UpstreamKind;

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

/// One configured upstream model host. The default upstream comes from the
/// flat `UPSTREAM_*` vars; extra named upstreams are declared in `UPSTREAMS`
/// and configured via `UPSTREAM_<NAME>_*` vars (see `.env.example`). Requests
/// are routed to an upstream by the model id they ask for.
#[derive(Debug, Clone)]
pub struct UpstreamSpec {
    /// Lowercase name used in logs and env-var lookups (`"default"` for the
    /// flat-var upstream).
    pub name: String,
    /// `None` => auto-detect (native Ollama probed first, then OpenAI `/v1`).
    pub kind: Option<UpstreamKind>,
    pub base: Url,
    pub api_key: Option<String>,
    pub thinking_hint: bool,
    /// Optional OpenAI-compatible reasoning effort values to advertise for this
    /// upstream's models. Native Ollama is intentionally excluded: `/api/show`
    /// reports only thinking support, not a trustworthy per-model levels list.
    pub reasoning_efforts: Vec<String>,
    /// Models this upstream serves. Non-empty => pinned: advertised and routed
    /// as-is, never probed. Empty => probed from the upstream.
    pub models: Vec<String>,
    /// Per-upstream cap on simultaneous generations. `None` => the global
    /// `UPSTREAM_MAX_CONCURRENCY`. Separate hosts get separate semaphores —
    /// the point of a second upstream is usually a second GPU/box.
    pub concurrency: Option<usize>,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub bind_addr: SocketAddr,
    /// Bearer token the app must present on every gated route. `None` disables
    /// auth entirely — every request is accepted unauthenticated. Unset/empty
    /// `PHANTASM_AUTH_TOKEN` => `None` (opt-in to an open server).
    pub auth_token: Option<String>,
    /// Separate bearer token for the observability routes (`/metrics`,
    /// `/dashboard/data`), so a scraper/browser credential never grants chat
    /// access — and the main token never opens metrics. Unset/empty => those
    /// routes fall back to `auth_token`.
    pub metrics_token: Option<String>,
    /// Browser CORS allow-list. Empty => CORS disabled (no `Access-Control-*`
    /// headers, no preflight handling) — the default, since the iOS app is not a
    /// browser and needs none. A single `*` entry allows any origin; otherwise
    /// it's an exact-match list of origins (e.g. `https://chat.example`).
    pub cors_allowed_origins: Vec<String>,

    // Upstream model host
    pub upstream_kind: Option<UpstreamKind>,
    pub upstream_base: Url,
    pub upstream_api_key: Option<String>,
    /// Send the Qwen-style `chat_template_kwargs.enable_thinking` hint to an
    /// OpenAI-compatible upstream (vLLM/llama.cpp templates honor it). Disable
    /// for a strict `/v1` server that rejects unknown body fields. Default on.
    pub upstream_thinking_hint: bool,
    /// Optional reasoning effort values advertised for the default
    /// OpenAI-compatible upstream. Ignored after auto-detection if the default
    /// upstream is native Ollama; rejected when UPSTREAM_KIND explicitly names
    /// native Ollama.
    pub upstream_reasoning_efforts: Vec<String>,
    pub default_model: String,
    /// Models advertised in /v1/capabilities. Empty => probe the upstream at startup.
    pub models: Vec<String>,
    /// Whether the flat/legacy default upstream was explicitly configured by
    /// env. If false and `UPSTREAMS` is non-empty, named upstreams define the
    /// full routing order without an implicit Ollama default inserted first.
    pub default_upstream_configured: bool,
    pub max_tool_iters: u8,
    pub upstream_concurrency: usize,
    /// Extra named upstreams (`UPSTREAMS=vllm,...` + `UPSTREAM_<NAME>_*` vars)
    /// beyond the default one described by the flat fields above. See
    /// [`Config::upstream_specs`].
    pub extra_upstreams: Vec<UpstreamSpec>,

    // Resumable turns (see `TurnRegistry`). A streaming turn started with an
    // `Idempotency-Key` keeps running across client disconnects (e.g. the app
    // backgrounding) and is buffered server-side so a reconnect replays it.
    /// How long a finished turn's buffered output is retained after completion so
    /// a late reconnect can still fetch it, before eviction.
    pub turn_result_ttl_s: u64,
    /// Cap on simultaneously buffered turns; the oldest is evicted past it. Each
    /// entry can hold a full turn (incl. an inline base64 image), so this bounds
    /// worst-case memory like `CONTINUATION_MAX`.
    pub turn_registry_max: usize,
    /// How long a still-running turn may have no attached client before the
    /// watchdog cancels it (frees the GPU for an app that was force-killed and
    /// will never reconnect). `0` disables the watchdog. Terminal turns are
    /// unaffected — they're retained for `turn_result_ttl_s`.
    pub turn_abandon_grace_s: u64,

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
    /// Longest edge (px) a vision input is allowed before it's downscaled on the
    /// way to Ollama. Models cap resolution internally, so larger wastes upload,
    /// memory, and re-sent-history bytes for no quality gain.
    pub image_max_dimension: u32,
    /// Only images whose source bytes exceed this are decoded+downscaled; smaller
    /// ones pass through after a cheap magic-byte sniff (bounds per-turn CPU when
    /// history images are re-sent every turn).
    pub image_downscale_trigger_bytes: usize,
    /// Timeout for fetching a remote (`http(s)`) input image, per attempt.
    pub image_fetch_timeout_ms: u64,

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
    pub time_enabled: bool,
    pub unit_convert_enabled: bool,
    pub weather_enabled: bool,
    pub open_meteo_base: Url,
    pub open_meteo_geocoding_base: Url,
    pub sports_enabled: bool,
    pub espn_base: Url,
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

    // Code execution tool. Runs untrusted, model-authored code in a per-execution
    // hardened container (default rootless podman). A long-lived warm pool of
    // pre-started containers lives in `AppState`; each container serves exactly
    // one execution and is then recycled, so no state or artifacts leak between
    // runs. Disabled unless `TOOL_CODE_EXEC` is set. Network egress is filtered
    // by a deployment-configured firewall on `code_exec_network` (internet yes,
    // internal/metadata no) — the orchestrator only attaches `--network`.
    pub code_exec_enabled: bool,
    /// Container CLI to shell out to (`podman` rootless by default, or `docker`).
    /// The flags used are identical across both runtimes.
    pub code_exec_runtime: String,
    /// Universal sandbox image bundling the supported interpreters + dispatcher.
    pub code_exec_image: String,
    /// Preconfigured, egress-firewalled network name passed as `--network`.
    /// `None` => the runtime default (no internal-egress filtering; dev/test only).
    pub code_exec_network: Option<String>,
    /// Languages the deployed image can run. Feeds the tool schema `language`
    /// enum and gates the tool. Empty => tool unusable.
    pub code_exec_languages: Vec<String>,
    /// Number of warm containers kept ready (and the max concurrent executions).
    pub code_exec_pool_size: usize,
    pub code_exec_timeout_s: u64,
    /// `--memory` value (e.g. "256m").
    pub code_exec_memory: String,
    /// `--cpus` value (a CFS ceiling, not a reservation; e.g. "2.0").
    pub code_exec_cpus: String,
    /// `--pids-limit` value (caps fork bombs).
    pub code_exec_pids_limit: u32,
    /// `--user` value the code runs as (e.g. "65534:65534", nobody).
    pub code_exec_run_user: String,
    /// Cap on captured stdout+stderr chars folded into the tool message.
    pub code_exec_output_chars: usize,
    /// Cap on accepted source size before a container is even touched.
    pub code_exec_max_code_bytes: usize,

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
    // references (`/v1/files/<id>/content`) instead of inline base64 — keeping re-sent
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
    /// URLs. Unset => emit site-relative `/v1/files/<id>/content` and let the app
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

    // Observability. `/metrics` (Prometheus, authed) is always on; the pair of
    // dashboard routes is gated because the HTML page itself is public.
    pub dashboard_enabled: bool,
    /// SQLite file backing the dashboard's durable history (per-turn/tool/usage
    /// rows — counts and timings only, never message content). `None` (explicit
    /// empty `PHANTASM_METRICS_DB`) => memory-only metrics: `/metrics` still
    /// works, the dashboard loses history across restarts.
    pub metrics_db: Option<PathBuf>,
    /// Rows older than this are pruned hourly by the store's writer thread.
    pub metrics_retention_days: u32,

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

        // Unset or empty => auth disabled (open server). Set => bearer-gated.
        // The loud warning for that state is logged from `main` via
        // `Config::auth_disabled` — `from_env` runs before tracing is
        // initialized, so a warning emitted here would vanish into the
        // pre-init no-op subscriber.
        let auth_token = env_nonempty("PHANTASM_AUTH_TOKEN");
        let metrics_token = env_nonempty("PHANTASM_METRICS_TOKEN");

        let upstream_kind = parse_upstream_kind()?;
        let upstream_base = parse_url_alias(
            "UPSTREAM_BASE_URL",
            "OLLAMA_BASE_URL",
            "http://localhost:11434",
        )?;
        let upstream_api_key = std::env::var("UPSTREAM_API_KEY")
            .ok()
            .filter(|s| !s.trim().is_empty());
        let upstream_thinking_hint = env_bool("UPSTREAM_THINKING_HINT", true);
        let upstream_reasoning_efforts =
            parse_reasoning_efforts("UPSTREAM_REASONING_EFFORTS", upstream_kind, "UPSTREAM_KIND")?;
        let default_model =
            env_or_alias("UPSTREAM_DEFAULT_MODEL", "OLLAMA_DEFAULT_MODEL", "llama3.1");
        let models = csv_alias("UPSTREAM_MODELS", "OLLAMA_MODELS");
        let extra_upstreams = parse_extra_upstreams()?;
        let default_upstream_configured = default_upstream_env_present();

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
            metrics_token,
            cors_allowed_origins: csv("PHANTASM_CORS_ALLOWED_ORIGINS"),
            upstream_kind,
            upstream_base,
            upstream_api_key,
            upstream_thinking_hint,
            upstream_reasoning_efforts,
            default_model,
            models,
            default_upstream_configured,
            extra_upstreams,
            max_tool_iters: env_parse("MAX_TOOL_ITERS", 5),
            upstream_concurrency: env_parse_alias(
                "UPSTREAM_MAX_CONCURRENCY",
                "OLLAMA_MAX_CONCURRENCY",
                4usize,
            )
            .max(1),
            turn_result_ttl_s: env_parse("TURN_RESULT_TTL_S", 24 * 60 * 60),
            turn_registry_max: env_parse("TURN_REGISTRY_MAX", 128usize),
            turn_abandon_grace_s: env_parse("TURN_ABANDON_GRACE_S", 300u64),
            max_request_body_bytes: env_parse("MAX_REQUEST_BODY_BYTES", 32 * 1024 * 1024),
            max_request_images: env_parse("MAX_REQUEST_IMAGES", 16usize),
            max_request_image_bytes: env_parse("MAX_REQUEST_IMAGE_BYTES", 16 * 1024 * 1024),
            image_max_dimension: env_parse("IMAGE_MAX_DIMENSION", 1536u32).max(1),
            image_downscale_trigger_bytes: env_parse(
                "IMAGE_DOWNSCALE_TRIGGER_BYTES",
                1024 * 1024usize,
            ),
            image_fetch_timeout_ms: env_parse("IMAGE_FETCH_TIMEOUT_MS", 10_000u64),
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
            time_enabled: env_bool("TOOL_TIME", false),
            unit_convert_enabled: env_bool("TOOL_UNIT_CONVERT", false),
            weather_enabled: env_bool("TOOL_WEATHER", false),
            open_meteo_base: parse_url("OPEN_METEO_BASE_URL", "https://api.open-meteo.com")?,
            open_meteo_geocoding_base: parse_url(
                "OPEN_METEO_GEOCODING_BASE_URL",
                "https://geocoding-api.open-meteo.com",
            )?,
            sports_enabled: env_bool("TOOL_SPORTS", false),
            espn_base: parse_url("ESPN_API_BASE_URL", "https://site.api.espn.com")?,
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
            code_exec_enabled: env_bool("TOOL_CODE_EXEC", false),
            code_exec_runtime: env_or("CODE_EXEC_RUNTIME", "podman"),
            code_exec_image: env_or("CODE_EXEC_IMAGE", "phantasm/code-exec:latest"),
            code_exec_network: std::env::var("CODE_EXEC_NETWORK")
                .ok()
                .filter(|s| !s.trim().is_empty()),
            code_exec_languages: {
                let langs = csv("CODE_EXEC_LANGUAGES");
                if langs.is_empty() {
                    ["python", "node", "bash", "ruby"]
                        .iter()
                        .map(|s| s.to_string())
                        .collect()
                } else {
                    langs
                }
            },
            code_exec_pool_size: env_parse("CODE_EXEC_POOL_SIZE", 2usize).max(1),
            code_exec_timeout_s: env_parse("CODE_EXEC_TIMEOUT_S", 30u64),
            code_exec_memory: env_or("CODE_EXEC_MEMORY", "256m"),
            code_exec_cpus: env_or("CODE_EXEC_CPUS", "2.0"),
            code_exec_pids_limit: env_parse("CODE_EXEC_PIDS_LIMIT", 128u32),
            code_exec_run_user: env_or("CODE_EXEC_USER", "65534:65534"),
            code_exec_output_chars: env_parse("CODE_EXEC_OUTPUT_CHARS", 16_000usize).max(500),
            code_exec_max_code_bytes: env_parse("CODE_EXEC_MAX_CODE_BYTES", 256 * 1024),
            image_gen_enabled,
            image_edit_enabled,
            comfy_base,
            comfy_timeout_s: env_parse("COMFYUI_TIMEOUT_S", 120u64),
            comfy_max_image_bytes: env_parse("COMFYUI_MAX_IMAGE_BYTES", 16 * 1024 * 1024),
            image_store_dir: env_path("IMAGE_STORE_DIR"),
            image_store_ttl_s: env_parse("IMAGE_STORE_TTL_S", 90 * 24 * 60 * 60),
            public_base_url: parse_opt_url("PUBLIC_BASE_URL")?,
            comfy_gen_workflow: env_path("COMFYUI_GEN_WORKFLOW"),
            comfy_gen_prompt: env_node("COMFYUI_GEN_PROMPT")?,
            comfy_gen_negative: env_node("COMFYUI_GEN_NEGATIVE")?,
            comfy_gen_width: env_node("COMFYUI_GEN_WIDTH")?,
            comfy_gen_height: env_node("COMFYUI_GEN_HEIGHT")?,
            comfy_gen_seed: env_node("COMFYUI_GEN_SEED")?,
            comfy_edit_workflow: env_path("COMFYUI_EDIT_WORKFLOW"),
            comfy_edit_prompt: env_node("COMFYUI_EDIT_PROMPT")?,
            comfy_edit_image: env_node("COMFYUI_EDIT_IMAGE")?,
            comfy_edit_seed: env_node("COMFYUI_EDIT_SEED")?,
            dashboard_enabled: env_bool("PHANTASM_DASHBOARD", true),
            // Unset => the default file next to the process; set-but-empty =>
            // memory-only (the opt-out), matching the "empty disables" idiom of
            // the other optional vars.
            metrics_db: match std::env::var("PHANTASM_METRICS_DB") {
                Ok(v) if v.trim().is_empty() => None,
                Ok(v) => Some(PathBuf::from(v.trim())),
                Err(_) => Some(PathBuf::from("phantasm-metrics.sqlite")),
            },
            metrics_retention_days: env_parse("PHANTASM_METRICS_RETENTION_DAYS", 90u32).max(1),
            log_format: if env_or("LOG_FORMAT", "text").eq_ignore_ascii_case("json") {
                LogFormat::Json
            } else {
                LogFormat::Text
            },
            log_content: env_bool("LOG_MESSAGE_CONTENT", false),
            presets: std::sync::OnceLock::new(),
        })
    }

    /// Every configured upstream, in routing-priority order. If flat/legacy
    /// default upstream env vars are set, that default comes first and named
    /// `UPSTREAMS` entries follow. If only named upstreams are configured, their
    /// declaration order is the full routing order. With no `UPSTREAMS`, the
    /// implicit Ollama default preserves the original single-upstream behavior.
    pub fn upstream_specs(&self) -> Vec<UpstreamSpec> {
        let include_default = self.default_upstream_configured || self.extra_upstreams.is_empty();
        let mut specs =
            Vec::with_capacity(self.extra_upstreams.len() + usize::from(include_default));
        if include_default {
            specs.push(UpstreamSpec {
                name: "default".into(),
                kind: self.upstream_kind,
                base: self.upstream_base.clone(),
                api_key: self.upstream_api_key.clone(),
                thinking_hint: self.upstream_thinking_hint,
                reasoning_efforts: self.upstream_reasoning_efforts.clone(),
                models: self.models.clone(),
                concurrency: None,
            });
        }
        specs.extend(self.extra_upstreams.iter().cloned());
        specs
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

    /// Whether bearer auth is disabled (no `PHANTASM_AUTH_TOKEN`): every request
    /// is accepted unauthenticated. Surfaced as a method so `main` can log the
    /// warning *after* `init_tracing` — a warning emitted during `from_env`
    /// would go to the no-op subscriber and never be seen.
    pub fn auth_disabled(&self) -> bool {
        self.auth_token.is_none()
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

    pub fn time_usable(&self) -> bool {
        self.time_enabled
    }

    pub fn unit_convert_usable(&self) -> bool {
        self.unit_convert_enabled
    }

    pub fn weather_usable(&self) -> bool {
        self.weather_enabled
    }

    pub fn sports_usable(&self) -> bool {
        self.sports_enabled
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

    /// Whether the code-execution tool can run: toggle on + at least one language
    /// configured. The warm pool's actual availability (runtime binary + image)
    /// is checked separately at startup; an unavailable pool degrades the tool to
    /// `None` so its schema is never offered.
    pub fn code_exec_usable(&self) -> bool {
        self.code_exec_enabled && !self.code_exec_languages.is_empty()
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

/// Read an env var, trim it, and drop it when unset or empty. `pub(crate)`
/// because the `pair` subcommand reads `PHANTASM_AUTH_TOKEN` (and its URL
/// vars) outside `Config::from_env`; sharing the reader keeps the two from
/// drifting — a `pair` QR embedding a token the server reads differently is
/// the worst failure mode for a pairing tool.
pub(crate) fn env_nonempty(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn env_or_alias(primary: &str, legacy: &str, default: &str) -> String {
    std::env::var(primary)
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var(legacy).ok().filter(|s| !s.trim().is_empty()))
        .unwrap_or_else(|| default.to_string())
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

fn env_parse_alias<T: std::str::FromStr>(primary: &str, legacy: &str, default: T) -> T {
    std::env::var(primary)
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var(legacy).ok())
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_path(key: &str) -> Option<PathBuf> {
    std::env::var(key)
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
}

fn env_node(key: &str) -> Result<Option<NodeInput>> {
    let Some(raw) = std::env::var(key).ok().filter(|s| !s.trim().is_empty()) else {
        return Ok(None);
    };
    NodeInput::parse(&raw)
        .map(Some)
        .with_context(|| format!("{key} must be a node input reference like 25.noise_seed"))
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

fn csv_alias(primary: &str, legacy: &str) -> Vec<String> {
    let raw = std::env::var(primary)
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var(legacy).ok().filter(|s| !s.trim().is_empty()));
    raw.map(|v| {
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

fn parse_url_alias(primary: &str, legacy: &str, default: &str) -> Result<Url> {
    let raw = env_or_alias(primary, legacy, default);
    Url::parse(&raw)
        .with_context(|| format!("{primary} or {legacy} must be a valid URL (got {raw:?})"))
}

fn parse_upstream_kind() -> Result<Option<UpstreamKind>> {
    parse_upstream_kind_key("UPSTREAM_KIND")
}

fn parse_upstream_kind_key(key: &str) -> Result<Option<UpstreamKind>> {
    let Some(raw) = std::env::var(key).ok().filter(|s| !s.trim().is_empty()) else {
        return Ok(None);
    };

    let normalized = raw.trim().to_ascii_lowercase().replace('-', "_");
    match normalized.as_str() {
        "auto" => Ok(None),
        "ollama" | "native_ollama" | "native" => Ok(Some(UpstreamKind::NativeOllama)),
        "openai" | "openai_compatible" | "vllm" | "llama_cpp" | "llamacpp" => {
            Ok(Some(UpstreamKind::OpenAICompatible))
        }
        _ => anyhow::bail!(
            "{key} must be auto, ollama, native_ollama, openai_compatible, vllm, or llama_cpp"
        ),
    }
}

fn parse_reasoning_efforts(
    key: &str,
    kind: Option<UpstreamKind>,
    kind_key: &str,
) -> Result<Vec<String>> {
    let efforts = csv(key);
    if efforts.is_empty() {
        return Ok(efforts);
    }
    if kind == Some(UpstreamKind::NativeOllama) {
        anyhow::bail!(
            "{key} is only supported for OpenAI-compatible upstreams; remove it or set \
             {kind_key}=openai_compatible/vllm"
        );
    }
    Ok(efforts)
}

/// Parse the extra named upstreams: `UPSTREAMS` is a CSV of names, each
/// configured via `UPSTREAM_<NAME>_*` vars (name uppercased, `-` => `_`).
/// A declared name missing its `BASE_URL` is a hard startup error — a silently
/// dropped upstream would strand the models meant to route to it.
fn parse_extra_upstreams() -> Result<Vec<UpstreamSpec>> {
    let names = csv("UPSTREAMS");
    let mut specs: Vec<UpstreamSpec> = Vec::with_capacity(names.len());
    for raw_name in names {
        let name = raw_name.to_ascii_lowercase();
        if name == "default" {
            anyhow::bail!(
                "UPSTREAMS must not contain \"default\" — that name is reserved for the \
                 upstream configured by the flat UPSTREAM_* vars"
            );
        }
        if !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            anyhow::bail!(
                "UPSTREAMS entry {raw_name:?} must be alphanumeric (plus `_`/`-`) so it can \
                 name UPSTREAM_<NAME>_* env vars"
            );
        }
        if specs.iter().any(|s| s.name == name) {
            anyhow::bail!("UPSTREAMS lists {name:?} more than once");
        }
        let prefix = format!("UPSTREAM_{}", name.to_ascii_uppercase().replace('-', "_"));
        let base_key = format!("{prefix}_BASE_URL");
        let raw_base = std::env::var(&base_key)
            .ok()
            .filter(|s| !s.trim().is_empty())
            .with_context(|| {
                format!("upstream {name:?} is declared in UPSTREAMS but {base_key} is unset")
            })?;
        let base = Url::parse(raw_base.trim())
            .with_context(|| format!("{base_key} must be a valid URL (got {raw_base:?})"))?;
        let kind_key = format!("{prefix}_KIND");
        let kind = parse_upstream_kind_key(&kind_key)?;
        specs.push(UpstreamSpec {
            kind,
            base,
            api_key: std::env::var(format!("{prefix}_API_KEY"))
                .ok()
                .filter(|s| !s.trim().is_empty()),
            thinking_hint: env_bool(&format!("{prefix}_THINKING_HINT"), true),
            reasoning_efforts: parse_reasoning_efforts(
                &format!("{prefix}_REASONING_EFFORTS"),
                kind,
                &kind_key,
            )?,
            models: csv(&format!("{prefix}_MODELS")),
            concurrency: parse_opt_usize(&format!("{prefix}_MAX_CONCURRENCY"))?.map(|n| n.max(1)),
            name,
        });
    }
    Ok(specs)
}

/// Parse an optional integer env var: absent/blank => `None`; present-but-
/// invalid is a hard startup error rather than a silent fallback (matching the
/// BASE_URL/KIND handling above — a typo'd value should not quietly run with
/// the default).
fn parse_opt_usize(key: &str) -> Result<Option<usize>> {
    let Some(raw) = std::env::var(key).ok().filter(|s| !s.trim().is_empty()) else {
        return Ok(None);
    };
    let n = raw
        .trim()
        .parse::<usize>()
        .with_context(|| format!("{key} must be a non-negative integer (got {raw:?})"))?;
    Ok(Some(n))
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

fn default_upstream_env_present() -> bool {
    const KEYS: &[&str] = &[
        "UPSTREAM_KIND",
        "UPSTREAM_BASE_URL",
        "UPSTREAM_API_KEY",
        "UPSTREAM_THINKING_HINT",
        "UPSTREAM_DEFAULT_MODEL",
        "UPSTREAM_MODELS",
        "UPSTREAM_MAX_CONCURRENCY",
        "OLLAMA_BASE_URL",
        "OLLAMA_DEFAULT_MODEL",
        "OLLAMA_MODELS",
        "OLLAMA_MAX_CONCURRENCY",
    ];
    KEYS.iter().any(|key| {
        std::env::var(key)
            .ok()
            .is_some_and(|value| !value.trim().is_empty())
    })
}

#[cfg(test)]
pub mod tests_support {
    use super::*;

    /// A minimal in-memory config for unit tests (no env, no I/O).
    pub fn minimal() -> Config {
        Config {
            bind_addr: "0.0.0.0:0".parse().unwrap(),
            auth_token: Some("test-token".into()),
            metrics_token: None,
            cors_allowed_origins: vec![],
            upstream_kind: None,
            upstream_base: "http://localhost:11434".parse().unwrap(),
            upstream_api_key: None,
            upstream_thinking_hint: true,
            upstream_reasoning_efforts: vec![],
            default_model: "m".into(),
            models: vec![],
            default_upstream_configured: true,
            extra_upstreams: vec![],
            max_tool_iters: 5,
            upstream_concurrency: 4,
            turn_result_ttl_s: 24 * 60 * 60,
            turn_registry_max: 128,
            turn_abandon_grace_s: 300,
            max_request_body_bytes: 32 * 1024 * 1024,
            max_request_images: 16,
            max_request_image_bytes: 16 * 1024 * 1024,
            image_max_dimension: 1536,
            image_downscale_trigger_bytes: 1024 * 1024,
            image_fetch_timeout_ms: 10_000,
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
            time_enabled: false,
            unit_convert_enabled: false,
            weather_enabled: false,
            open_meteo_base: "https://api.open-meteo.com".parse().unwrap(),
            open_meteo_geocoding_base: "https://geocoding-api.open-meteo.com".parse().unwrap(),
            sports_enabled: false,
            espn_base: "https://site.api.espn.com".parse().unwrap(),
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
            code_exec_enabled: false,
            code_exec_runtime: "podman".into(),
            code_exec_image: "phantasm/code-exec:latest".into(),
            code_exec_network: None,
            code_exec_languages: vec!["python".into(), "bash".into()],
            code_exec_pool_size: 2,
            code_exec_timeout_s: 30,
            code_exec_memory: "256m".into(),
            code_exec_cpus: "2.0".into(),
            code_exec_pids_limit: 128,
            code_exec_run_user: "65534:65534".into(),
            code_exec_output_chars: 16_000,
            code_exec_max_code_bytes: 256 * 1024,
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
            dashboard_enabled: true,
            metrics_db: None,
            metrics_retention_days: 90,
            log_format: LogFormat::Text,
            log_content: false,
            presets: std::sync::OnceLock::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        csv_alias, env_node, env_or_alias, env_parse_alias, parse_extra_upstreams,
        parse_reasoning_efforts, parse_upstream_kind, parse_url_alias, NodeInput,
    };
    use crate::ollama::UpstreamKind;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    #[test]
    fn auth_disabled_reflects_missing_token() {
        let mut cfg = crate::config::tests_support::minimal();
        assert!(!cfg.auth_disabled(), "a set token means auth is on");
        cfg.auth_token = None;
        assert!(cfg.auth_disabled(), "no token means the server is open");
    }

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

    #[test]
    fn env_node_accepts_absent_blank_and_valid_values() {
        let _guard = env_lock();
        const KEY: &str = "PHANTASM_TEST_COMFY_NODE";

        std::env::remove_var(KEY);
        assert!(env_node(KEY).unwrap().is_none());

        std::env::set_var(KEY, "  ");
        assert!(env_node(KEY).unwrap().is_none());

        std::env::set_var(KEY, "25.noise_seed");
        let parsed = env_node(KEY).unwrap().unwrap();
        assert_eq!(parsed.node, "25");
        assert_eq!(parsed.key, "noise_seed");

        std::env::remove_var(KEY);
    }

    #[test]
    fn env_node_rejects_present_malformed_value() {
        let _guard = env_lock();
        const KEY: &str = "PHANTASM_TEST_COMFY_NODE";

        std::env::set_var(KEY, "25");
        let err = env_node(KEY).unwrap_err().to_string();
        assert!(
            err.contains(KEY) && err.contains("25.noise_seed"),
            "unexpected error: {err}"
        );

        std::env::remove_var(KEY);
    }

    #[test]
    fn reasoning_efforts_are_openai_compatible_metadata() {
        let _guard = env_lock();
        const KEY: &str = "UPSTREAM_REASONING_EFFORTS";

        std::env::remove_var(KEY);
        assert!(parse_reasoning_efforts(KEY, None, "UPSTREAM_KIND")
            .unwrap()
            .is_empty());

        std::env::set_var(KEY, "none, low, medium, high");
        assert_eq!(
            parse_reasoning_efforts(KEY, Some(UpstreamKind::OpenAICompatible), "UPSTREAM_KIND")
                .unwrap(),
            ["none", "low", "medium", "high"]
        );

        let err = parse_reasoning_efforts(KEY, Some(UpstreamKind::NativeOllama), "UPSTREAM_KIND")
            .unwrap_err()
            .to_string();
        assert!(err.contains(KEY), "got: {err}");

        std::env::remove_var(KEY);
    }

    #[test]
    fn upstream_env_aliases_prefer_new_names() {
        let _guard = env_lock();
        const BASE: &str = "UPSTREAM_BASE_URL";
        const LEGACY_BASE: &str = "OLLAMA_BASE_URL";
        const MODEL: &str = "UPSTREAM_DEFAULT_MODEL";
        const LEGACY_MODEL: &str = "OLLAMA_DEFAULT_MODEL";
        const MODELS: &str = "UPSTREAM_MODELS";
        const LEGACY_MODELS: &str = "OLLAMA_MODELS";
        const CONCURRENCY: &str = "UPSTREAM_MAX_CONCURRENCY";
        const LEGACY_CONCURRENCY: &str = "OLLAMA_MAX_CONCURRENCY";

        for key in [
            BASE,
            LEGACY_BASE,
            MODEL,
            LEGACY_MODEL,
            MODELS,
            LEGACY_MODELS,
            CONCURRENCY,
            LEGACY_CONCURRENCY,
        ] {
            std::env::remove_var(key);
        }

        std::env::set_var(LEGACY_BASE, "http://legacy:11434");
        std::env::set_var(BASE, "http://new:8000");
        assert_eq!(
            parse_url_alias(BASE, LEGACY_BASE, "http://default")
                .unwrap()
                .as_str(),
            "http://new:8000/"
        );

        std::env::set_var(LEGACY_MODEL, "legacy-model");
        std::env::set_var(MODEL, "new-model");
        assert_eq!(env_or_alias(MODEL, LEGACY_MODEL, "default"), "new-model");

        std::env::set_var(LEGACY_MODELS, "legacy-a,legacy-b");
        std::env::set_var(MODELS, "new-a, new-b");
        assert_eq!(csv_alias(MODELS, LEGACY_MODELS), ["new-a", "new-b"]);

        std::env::set_var(LEGACY_CONCURRENCY, "2");
        std::env::set_var(CONCURRENCY, "7");
        assert_eq!(env_parse_alias(CONCURRENCY, LEGACY_CONCURRENCY, 4usize), 7);
        std::env::set_var(CONCURRENCY, "  ");
        assert_eq!(env_parse_alias(CONCURRENCY, LEGACY_CONCURRENCY, 4usize), 2);

        for key in [
            BASE,
            LEGACY_BASE,
            MODEL,
            LEGACY_MODEL,
            MODELS,
            LEGACY_MODELS,
            CONCURRENCY,
            LEGACY_CONCURRENCY,
        ] {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn extra_upstreams_parse_named_env_vars() {
        let _guard = env_lock();
        let keys = [
            "UPSTREAMS",
            "UPSTREAM_VLLM_KIND",
            "UPSTREAM_VLLM_BASE_URL",
            "UPSTREAM_VLLM_API_KEY",
            "UPSTREAM_VLLM_MODELS",
            "UPSTREAM_VLLM_MAX_CONCURRENCY",
            "UPSTREAM_VLLM_THINKING_HINT",
            "UPSTREAM_VLLM_REASONING_EFFORTS",
        ];
        for key in keys {
            std::env::remove_var(key);
        }

        // No UPSTREAMS => no extras (the back-compat single-upstream path).
        assert!(parse_extra_upstreams().unwrap().is_empty());

        // A declared upstream without a base URL is a startup error, not a
        // silently dropped backend.
        std::env::set_var("UPSTREAMS", "vllm");
        let err = parse_extra_upstreams().unwrap_err().to_string();
        assert!(err.contains("UPSTREAM_VLLM_BASE_URL"), "got: {err}");

        std::env::set_var("UPSTREAM_VLLM_KIND", "vllm");
        std::env::set_var("UPSTREAM_VLLM_BASE_URL", "http://localhost:8000");
        std::env::set_var("UPSTREAM_VLLM_API_KEY", "sk-test");
        std::env::set_var("UPSTREAM_VLLM_MODELS", "qwen3-32b, qwen3-32b-awq");
        std::env::set_var("UPSTREAM_VLLM_MAX_CONCURRENCY", "2");
        std::env::set_var("UPSTREAM_VLLM_THINKING_HINT", "false");
        std::env::set_var("UPSTREAM_VLLM_REASONING_EFFORTS", "none, low, medium, high");
        let specs = parse_extra_upstreams().unwrap();
        assert_eq!(specs.len(), 1);
        let spec = &specs[0];
        assert_eq!(spec.name, "vllm");
        assert_eq!(spec.kind, Some(UpstreamKind::OpenAICompatible));
        assert_eq!(spec.base.as_str(), "http://localhost:8000/");
        assert_eq!(spec.api_key.as_deref(), Some("sk-test"));
        assert_eq!(spec.models, ["qwen3-32b", "qwen3-32b-awq"]);
        assert_eq!(spec.concurrency, Some(2));
        assert!(!spec.thinking_hint);
        assert_eq!(spec.reasoning_efforts, ["none", "low", "medium", "high"]);

        // Reasoning effort lists are explicit OpenAI-compatible metadata, not
        // allowed on native Ollama where the upstream does not expose levels.
        std::env::set_var("UPSTREAM_VLLM_KIND", "ollama");
        let err = parse_extra_upstreams().unwrap_err().to_string();
        assert!(
            err.contains("UPSTREAM_VLLM_REASONING_EFFORTS"),
            "got: {err}"
        );
        std::env::set_var("UPSTREAM_VLLM_KIND", "vllm");

        // Reserved / duplicate names are rejected.
        std::env::set_var("UPSTREAMS", "default");
        assert!(parse_extra_upstreams().is_err());
        std::env::set_var("UPSTREAMS", "vllm,vllm");
        assert!(parse_extra_upstreams().is_err());

        // An unparseable concurrency is a startup error, not a silent default.
        std::env::set_var("UPSTREAMS", "vllm");
        std::env::set_var("UPSTREAM_VLLM_MAX_CONCURRENCY", "two");
        let err = parse_extra_upstreams().unwrap_err().to_string();
        assert!(err.contains("UPSTREAM_VLLM_MAX_CONCURRENCY"), "got: {err}");

        for key in keys {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn upstream_specs_put_the_default_upstream_first() {
        let mut cfg = crate::config::tests_support::minimal();
        cfg.models = vec!["small".into()];
        cfg.extra_upstreams = vec![super::UpstreamSpec {
            name: "vllm".into(),
            kind: Some(UpstreamKind::OpenAICompatible),
            base: "http://localhost:8000".parse().unwrap(),
            api_key: None,
            thinking_hint: true,
            reasoning_efforts: vec!["low".into(), "high".into()],
            models: vec!["big".into()],
            concurrency: None,
        }];
        let specs = cfg.upstream_specs();
        assert_eq!(specs.len(), 2);
        assert_eq!(specs[0].name, "default");
        assert_eq!(specs[0].models, ["small"]);
        assert_eq!(specs[1].name, "vllm");
    }

    #[test]
    fn upstream_specs_named_only_do_not_inject_implicit_default() {
        let mut cfg = crate::config::tests_support::minimal();
        cfg.default_upstream_configured = false;
        cfg.extra_upstreams = vec![
            super::UpstreamSpec {
                name: "vllm".into(),
                kind: Some(UpstreamKind::OpenAICompatible),
                base: "http://localhost:18000".parse().unwrap(),
                api_key: None,
                thinking_hint: true,
                reasoning_efforts: vec![],
                models: vec!["big".into()],
                concurrency: None,
            },
            super::UpstreamSpec {
                name: "ollama".into(),
                kind: Some(UpstreamKind::NativeOllama),
                base: "http://localhost:11434".parse().unwrap(),
                api_key: None,
                thinking_hint: true,
                reasoning_efforts: vec![],
                models: vec!["small".into()],
                concurrency: None,
            },
        ];
        let specs = cfg.upstream_specs();
        assert_eq!(specs.len(), 2);
        assert_eq!(specs[0].name, "vllm");
        assert_eq!(specs[1].name, "ollama");
    }

    #[test]
    fn upstream_kind_parses_aliases() {
        let _guard = env_lock();
        const KEY: &str = "UPSTREAM_KIND";

        std::env::remove_var(KEY);
        assert_eq!(parse_upstream_kind().unwrap(), None);

        std::env::set_var(KEY, "auto");
        assert_eq!(parse_upstream_kind().unwrap(), None);

        std::env::set_var(KEY, "native-ollama");
        assert_eq!(
            parse_upstream_kind().unwrap(),
            Some(UpstreamKind::NativeOllama)
        );

        std::env::set_var(KEY, "vllm");
        assert_eq!(
            parse_upstream_kind().unwrap(),
            Some(UpstreamKind::OpenAICompatible)
        );

        std::env::set_var(KEY, "llama_cpp");
        assert_eq!(
            parse_upstream_kind().unwrap(),
            Some(UpstreamKind::OpenAICompatible)
        );

        std::env::set_var(KEY, "bad");
        assert!(parse_upstream_kind().is_err());

        std::env::remove_var(KEY);
    }
}
