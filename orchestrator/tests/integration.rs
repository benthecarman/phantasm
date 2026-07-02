//! End-to-end smoke tests: the real orchestrator router in front of a mock
//! Ollama (an in-process axum app serving NDJSON). No real backends required.

use std::sync::Arc;

use axum::http::header::CONTENT_TYPE;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::Router;
use phantasm_orchestrator::config::{Config, LogFormat};
use phantasm_orchestrator::ollama::{UpstreamChatBackend, UpstreamKind};
use phantasm_orchestrator::state::{CapabilitySnapshot, ModelCapabilities, ModelInfo};
use phantasm_orchestrator::upstreams::{UpstreamEntry, UpstreamSet};
use phantasm_orchestrator::{probe_capabilities, routes};
use tokio::sync::Mutex;

const TOKEN: &str = "test-token";
type RecordedRequests = Arc<Mutex<Vec<serde_json::Value>>>;

/// Spawn an HTTP server on an ephemeral port; return its base URL.
async fn spawn(app: Router) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    format!("http://{addr}")
}

/// A mock Ollama that returns a two-token streaming `/api/chat` response and a
/// one-model `/api/tags`.
fn mock_ollama() -> Router {
    mock_ollama_with_recorder(None)
}

fn mock_ollama_recording(requests: RecordedRequests) -> Router {
    mock_ollama_with_recorder(Some(requests))
}

fn mock_ollama_show_error() -> Router {
    Router::new()
        .route(
            "/api/tags",
            get(|| async { axum::Json(serde_json::json!({"models":[{"name":"m"}]})) }),
        )
        .route(
            "/api/show",
            post(|| async {
                (
                    StatusCode::NOT_FOUND,
                    axum::Json(serde_json::json!({"error":"missing model"})),
                )
            }),
        )
}

fn mock_ollama_app_tool_call() -> Router {
    Router::new()
        .route(
            "/api/chat",
            post(|body: axum::extract::Json<serde_json::Value>| async move {
                let streaming = body.0.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
                if streaming {
                    "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"unused\"},\"done\":true,\"done_reason\":\"stop\"}\n"
                } else {
                    "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"tool_calls\":[\
                       {\"function\":{\"name\":\"ask_user_input\",\"arguments\":{\"questions\":[{\"question\":\"Pick one\",\"options\":[\"A\",\"B\"],\"type\":\"single_select\"}]}}}\
                     ]},\"done\":true,\"done_reason\":\"stop\"}\n"
                }
            }),
        )
        .route(
            "/api/tags",
            get(|| async { axum::Json(serde_json::json!({"models":[{"name":"m"}]})) }),
        )
}

fn mock_ollama_with_recorder(requests: Option<RecordedRequests>) -> Router {
    Router::new()
        .route(
            "/api/chat",
            post(move |body: axum::extract::Json<serde_json::Value>| {
                let requests = requests.clone();
                async move {
                    let streaming = body.0.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
                    if let Some(requests) = requests {
                        requests.lock().await.push(body.0.clone());
                    }
                    if streaming {
                        // The final chunk carries Ollama's generation stats, like
                        // the real API — the metrics tests assert these flow into
                        // the token counters.
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}\n\
                         {\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\" world\"},\"done\":true,\"done_reason\":\"stop\",\
                          \"prompt_eval_count\":7,\"eval_count\":30,\"eval_duration\":1500000000}\n"
                    } else {
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello world\"},\"done\":true}"
                    }
                }
            }),
        )
        .route(
            "/api/tags",
            get(|| async { axum::Json(serde_json::json!({"models":[{"name":"m"}]})) }),
        )
}

/// A mock Ollama for the mixed app+server tool-call flow. The first turn (no
/// `tool`-role message in the history) returns an assistant calling BOTH a
/// server tool (`calculator`) and an app tool (`ask_user`). Once the history
/// carries a `tool` result (the resumed continuation), it returns a plain
/// answer; streaming requests stream "Hello world".
fn mock_ollama_mixed_tools(requests: RecordedRequests) -> Router {
    Router::new()
        .route(
            "/api/chat",
            post(move |body: axum::extract::Json<serde_json::Value>| {
                let requests = requests.clone();
                async move {
                    let streaming =
                        body.0.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
                    let resumed = body.0["messages"]
                        .as_array()
                        .is_some_and(|ms| ms.iter().any(|m| m["role"] == "tool"));
                    requests.lock().await.push(body.0.clone());
                    if streaming {
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}\n\
                         {\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\" world\"},\"done\":true,\"done_reason\":\"stop\"}\n"
                    } else if resumed {
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"resolved\"},\"done\":true,\"done_reason\":\"stop\"}\n"
                    } else {
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"tool_calls\":[\
                           {\"function\":{\"name\":\"calculator\",\"arguments\":{\"expression\":\"1+1\"}}},\
                           {\"function\":{\"name\":\"ask_user\",\"arguments\":{\"question\":\"which?\"}}}\
                         ]},\"done\":true,\"done_reason\":\"stop\"}\n"
                    }
                }
            }),
        )
        .route(
            "/api/tags",
            get(|| async { axum::Json(serde_json::json!({"models":[{"name":"m"}]})) }),
        )
}

/// A mock Ollama for the code-execution flow. The first turn (no `tool`-role
/// message) returns an assistant calling the server-side `code_exec` tool; once a
/// `tool` result is present it stops calling tools, and streaming requests stream
/// "Hello world" as the final answer.
fn mock_ollama_code_exec(requests: RecordedRequests) -> Router {
    Router::new()
        .route(
            "/api/chat",
            post(move |body: axum::extract::Json<serde_json::Value>| {
                let requests = requests.clone();
                async move {
                    let streaming =
                        body.0.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
                    let resumed = body.0["messages"]
                        .as_array()
                        .is_some_and(|ms| ms.iter().any(|m| m["role"] == "tool"));
                    requests.lock().await.push(body.0.clone());
                    if streaming {
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}\n\
                         {\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\" world\"},\"done\":true,\"done_reason\":\"stop\"}\n"
                    } else if resumed {
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"done\":true,\"done_reason\":\"stop\"}\n"
                    } else {
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"tool_calls\":[\
                           {\"function\":{\"name\":\"code_exec\",\"arguments\":{\"language\":\"python\",\"code\":\"print(1)\"}}}\
                         ]},\"done\":true,\"done_reason\":\"stop\"}\n"
                    }
                }
            }),
        )
        .route(
            "/api/tags",
            get(|| async { axum::Json(serde_json::json!({"models":[{"name":"m"}]})) }),
        )
}

/// A mock OpenAI-compatible backend: no `/api/tags`, yes `/v1/models` and
/// `/v1/chat/completions`.
fn mock_openai_compatible() -> Router {
    Router::new()
        .route(
            "/v1/chat/completions",
            post(|body: axum::extract::Json<serde_json::Value>| async move {
                let streaming = body.0.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
                if streaming {
                    assert_eq!(
                        body.0["stream_options"]["include_usage"],
                        true,
                        "OpenAI-compatible streams should request usage"
                    );
                    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n\
                                data: {\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish_reason\":null}]}\n\n\
                                data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n\
                                data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}\n\n\
                                data: [DONE]\n\n";
                    ([(CONTENT_TYPE, "text/event-stream")], body).into_response()
                } else {
                    axum::Json(serde_json::json!({
                        "choices": [{
                            "message": { "role": "assistant", "content": "Hello world" },
                            "finish_reason": "stop"
                        }]
                    }))
                    .into_response()
                }
            }),
        )
        .route(
            "/v1/models",
            get(|| async { axum::Json(serde_json::json!({"data":[{"id":"m"}]})) }),
        )
}

fn mock_openai_compatible_with_json_tags_error() -> Router {
    mock_openai_compatible().route(
        "/api/tags",
        get(|| async {
            (
                StatusCode::NOT_FOUND,
                axum::Json(serde_json::json!({"error":"not found"})),
            )
        }),
    )
}

/// Like [`mock_openai_compatible`] but `/v1/chat/completions` fails with a 500
/// and a detail body, so we can assert the orchestrator surfaces the upstream
/// error rather than masking it.
fn mock_openai_compatible_erroring() -> Router {
    Router::new()
        .route(
            "/v1/chat/completions",
            post(|| async { (StatusCode::INTERNAL_SERVER_ERROR, "upstream boom").into_response() }),
        )
        .route(
            "/v1/models",
            get(|| async { axum::Json(serde_json::json!({"data":[{"id":"m"}]})) }),
        )
}

fn mock_openai_compatible_strict_stream_options(requests: RecordedRequests) -> Router {
    Router::new()
        .route(
            "/v1/chat/completions",
            post(move |body: axum::extract::Json<serde_json::Value>| {
                let requests = requests.clone();
                async move {
                    requests.lock().await.push(body.0.clone());
                    if body.0.get("stream_options").is_some() {
                        return (StatusCode::BAD_REQUEST, "unknown field stream_options")
                            .into_response();
                    }
                    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"strict\"},\"finish_reason\":null}]}\n\n\
                                data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n\
                                data: [DONE]\n\n";
                    ([(CONTENT_TYPE, "text/event-stream")], body).into_response()
                }
            }),
        )
        .route(
            "/v1/models",
            get(|| async { axum::Json(serde_json::json!({"data":[{"id":"m"}]})) }),
        )
}

/// A mock OpenAI-compatible backend for vLLM/llama.cpp-style server tool use.
/// The first non-streaming call returns a standard OpenAI `tool_calls` message.
/// After the orchestrator appends a `tool` role result, the final streaming pass
/// emits "Hello world".
fn mock_openai_compatible_tool_call(requests: RecordedRequests) -> Router {
    Router::new()
        .route(
            "/v1/chat/completions",
            post(move |body: axum::extract::Json<serde_json::Value>| {
                let requests = requests.clone();
                async move {
                    let streaming =
                        body.0.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
                    let resumed = body.0["messages"]
                        .as_array()
                        .is_some_and(|ms| ms.iter().any(|m| m["role"] == "tool"));
                    requests.lock().await.push(body.0.clone());
                    if streaming {
                        if body.0.get("tools").is_some() {
                            return (StatusCode::BAD_REQUEST, "final stream must not include tools")
                                .into_response();
                        }
                        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n\
                                    data: {\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish_reason\":null}]}\n\n\
                                    data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n\
                                    data: [DONE]\n\n";
                        ([(CONTENT_TYPE, "text/event-stream")], body).into_response()
                    } else if resumed {
                        let tool_messages = body.0["messages"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter(|m| m["role"] == "tool");
                        for message in tool_messages {
                            if message.get("name").is_some() {
                                return (
                                    StatusCode::BAD_REQUEST,
                                    "OpenAI-compatible tool messages must omit name",
                                )
                                    .into_response();
                            }
                            if message.get("tool_call_id").is_none() {
                                return (
                                    StatusCode::BAD_REQUEST,
                                    "OpenAI-compatible tool messages require tool_call_id",
                                )
                                    .into_response();
                            }
                        }
                        axum::Json(serde_json::json!({
                            "choices": [{
                                "message": { "role": "assistant", "content": "resolved" },
                                "finish_reason": "stop"
                            }]
                        }))
                        .into_response()
                    } else {
                        axum::Json(serde_json::json!({
                            "choices": [{
                                "message": {
                                    "role": "assistant",
                                    "content": null,
                                    "tool_calls": [{
                                        "id": "call_calc",
                                        "type": "function",
                                        "function": {
                                            "name": "calculator",
                                            "arguments": "{\"expression\":\"1+1\"}"
                                        }
                                    }]
                                },
                                "finish_reason": "tool_calls"
                            }]
                        }))
                        .into_response()
                    }
                }
            }),
        )
        .route(
            "/v1/models",
            get(|| async { axum::Json(serde_json::json!({"data":[{"id":"m"}]})) }),
        )
}

fn test_config(upstream_base: &str) -> Config {
    Config {
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        auth_token: Some(TOKEN.into()),
        metrics_token: None,
        cors_allowed_origins: vec![],
        upstream_kind: None,
        upstream_base: upstream_base.parse().unwrap(),
        upstream_api_key: None,
        upstream_thinking_hint: true,
        default_model: "m".into(),
        models: vec!["m".into()],
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
        research_deep_fanout: 4,
        research_deep_searches_per_subq: 3,
        research_deep_verify: true,
        research_quick_fanout: 2,
        research_quick_searches_per_subq: 2,
        research_quick_verify: false,
        research_fanout_concurrency: 2,
        dashboard_enabled: true,
        metrics_db: None,
        metrics_retention_days: 90,
        log_format: LogFormat::Text,
        log_content: false,
        presets: Default::default(),
    }
}

fn test_capabilities() -> CapabilitySnapshot {
    CapabilitySnapshot {
        version: "test".into(),
        models: vec![ModelInfo {
            id: "m".into(),
            capabilities: Some(ModelCapabilities {
                completion: true,
                vision: false,
                audio: false,
                tools: false,
                insert: false,
                thinking: false,
                embedding: false,
            }),
            context_length: Some(4096),
        }],
        tool_selectors: vec![],
        modes: vec![],
    }
}

async fn spawn_orchestrator(upstream_base: &str) -> String {
    spawn_orchestrator_with_kind(upstream_base, UpstreamKind::NativeOllama).await
}

async fn spawn_orchestrator_with_kind(upstream_base: &str, upstream_kind: UpstreamKind) -> String {
    let cfg = Arc::new(test_config(upstream_base));
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, upstream_kind);
    spawn(routes::router(state)).await
}

/// Like `spawn_orchestrator`, but with a config tweak (e.g. metrics store path,
/// dashboard toggle) applied before the state is built.
async fn spawn_orchestrator_with_cfg(
    upstream_base: &str,
    tweak: impl FnOnce(&mut Config),
) -> String {
    let mut cfg = test_config(upstream_base);
    tweak(&mut cfg);
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, UpstreamKind::NativeOllama);
    spawn(routes::router(state)).await
}

/// Like `spawn_orchestrator`, but with the `calculator` server tool enabled so
/// the mixed app+server tool-call flow has a real server tool to execute.
async fn spawn_orchestrator_with_calculator(upstream_base: &str) -> String {
    spawn_orchestrator_with_calculator_kind(upstream_base, UpstreamKind::NativeOllama).await
}

async fn spawn_orchestrator_with_calculator_kind(
    upstream_base: &str,
    upstream_kind: UpstreamKind,
) -> String {
    let mut cfg = test_config(upstream_base);
    cfg.calculator_enabled = true;
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, upstream_kind);
    spawn(routes::router(state)).await
}

/// Like `spawn_orchestrator`, but with the `code_exec` server tool enabled. The
/// runtime is a tiny fake that passes deployment preflight (runtime/image/network)
/// but fails container starts — no real Docker/Podman is needed in CI. This
/// exercises the wiring and the non-fatal failure path (NFR-O6): the tool folds
/// its error into the `tool` message and the turn still completes.
async fn spawn_orchestrator_with_code_exec(upstream_base: &str) -> String {
    let mut cfg = test_config(upstream_base);
    cfg.code_exec_enabled = true;
    cfg.code_exec_runtime = fake_code_exec_runtime();
    cfg.code_exec_network = Some("phantasm-code-exec".into());
    cfg.code_exec_languages = vec!["python".into()];
    cfg.code_exec_pool_size = 1;
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, UpstreamKind::NativeOllama);
    spawn(routes::router(state)).await
}

fn fake_code_exec_runtime() -> String {
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    let mut file = tempfile::NamedTempFile::new().unwrap();
    writeln!(
        file,
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then exit 0; fi
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then exit 0; fi
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then exit 0; fi
if [ "$1" = "rm" ]; then exit 0; fi
echo "fake runtime refuses to start containers" >&2
exit 1
"#
    )
    .unwrap();
    #[cfg(unix)]
    {
        let mut perms = file.as_file().metadata().unwrap().permissions();
        perms.set_mode(0o755);
        file.as_file().set_permissions(perms).unwrap();
    }
    let (_file, path) = file.keep().unwrap();
    path.to_string_lossy().into_owned()
}

/// A model `code_exec` call is executed server-side and never forwarded to the
/// app; when the sandbox backend is unavailable the tool failure is folded into
/// the `tool` message (non-fatal) and the turn still streams a final answer.
#[tokio::test]
async fn code_exec_runs_server_side_and_failure_is_non_fatal() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let ollama = spawn(mock_ollama_code_exec(requests.clone())).await;
    let base = spawn_orchestrator_with_code_exec(&ollama).await;
    let client = reqwest::Client::new();

    let resp = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m", "stream": true,
            "messages": [{"role": "user", "content": "run some code"}],
            "tools": [{ "type": "function", "function": { "name": "code_exec" } }],
        }))
        .send()
        .await
        .unwrap();
    assert!(resp.status().is_success());
    let body = resp.text().await.unwrap();

    // The turn completes with a streamed answer; the code_exec call is resolved
    // server-side, so nothing is forwarded to the app as a tool call.
    let mut content = String::new();
    let mut forwarded_tool_calls = 0;
    for line in body.lines() {
        let Some(data) = line.strip_prefix("data: ") else {
            continue;
        };
        if data == "[DONE]" {
            continue;
        }
        let v: serde_json::Value = serde_json::from_str(data).unwrap();
        if let Some(c) = v["choices"][0]["delta"]["content"].as_str() {
            content.push_str(c);
        }
        if v["choices"][0]["delta"]["tool_calls"].is_array() {
            forwarded_tool_calls += 1;
        }
    }
    assert_eq!(content, "Hello world", "the turn streams a final answer");
    assert_eq!(
        forwarded_tool_calls, 0,
        "code_exec is a server tool and is never forwarded to the app"
    );

    // A resolution request carried the folded code_exec tool result (native Ollama
    // puts the tool's function name in `tool_name`), proving it was dispatched and
    // its failure was handled non-fatally rather than aborting the turn.
    let requests = requests.lock().await;
    let resolved = requests.iter().any(|r| {
        r["messages"]
            .as_array()
            .is_some_and(|ms| ms.iter().any(|m| m["tool_name"] == "code_exec"))
    });
    assert!(
        resolved,
        "a resolution request includes the folded code_exec tool result"
    );
}

#[derive(Debug, PartialEq)]
enum SseContractEvent {
    Json(serde_json::Value),
    Done,
}

fn fixture_events(name: &str) -> Vec<SseContractEvent> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../docs/contract-fixtures/orchestrator-sse")
        .join(name);
    parse_sse_contract(&std::fs::read_to_string(path).unwrap())
}

fn response_events(body: &str) -> Vec<SseContractEvent> {
    parse_sse_contract(body)
        .into_iter()
        .map(|event| match event {
            SseContractEvent::Json(mut value) => {
                if let Some(obj) = value.as_object_mut() {
                    obj.insert("id".into(), serde_json::json!("chatcmpl-fixture"));
                    obj.insert("created".into(), serde_json::json!(1));
                }
                if let Some(calls) = value
                    .pointer_mut("/choices/0/delta/tool_calls")
                    .and_then(serde_json::Value::as_array_mut)
                {
                    for call in calls {
                        if let Some(obj) = call.as_object_mut() {
                            obj.insert("id".into(), serde_json::json!("call_ask"));
                        }
                    }
                }
                SseContractEvent::Json(value)
            }
            SseContractEvent::Done => SseContractEvent::Done,
        })
        .collect()
}

fn parse_sse_contract(raw: &str) -> Vec<SseContractEvent> {
    raw.lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .map(|data| {
            if data == "[DONE]" {
                SseContractEvent::Done
            } else {
                SseContractEvent::Json(serde_json::from_str(data).unwrap())
            }
        })
        .collect()
}

#[tokio::test]
async fn app_tool_call_stream_matches_contract_fixture() {
    let ollama = spawn(mock_ollama_app_tool_call()).await;
    let base = spawn_orchestrator(&ollama).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "stream": true,
            "messages": [{"role": "user", "content": "ask me"}],
            "tools": [{
                "type": "function",
                "function": {
                    "name": "ask_user_input",
                    "description": "Ask the user",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "questions": { "type": "array" }
                        },
                        "required": ["questions"]
                    }
                }
            }]
        }))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    assert_eq!(
        response_events(&resp.text().await.unwrap()),
        fixture_events("app-tool-call.sse")
    );
}

/// When a turn mixes a server tool call (`calculator`) and an app tool call
/// (`ask_user`), the server call runs *now*, only the app call is forwarded, and
/// the resolved history is held server-side. The continuation request — carrying
/// the app's answer — resumes from that held history, so the server work is
/// preserved (not dropped, not re-run by the model).
#[tokio::test]
async fn mixed_tool_calls_hold_server_work_and_resume() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let ollama = spawn(mock_ollama_mixed_tools(requests.clone())).await;
    let base = spawn_orchestrator_with_calculator(&ollama).await;
    let client = reqwest::Client::new();

    let tools = serde_json::json!([
        { "type": "function", "function": { "name": "calculator" } },
        { "type": "function", "function": {
            "name": "ask_user", "description": "ask the user",
            "parameters": { "type": "object", "properties": {} }
        }},
    ]);

    // Turn 1: model calls calculator + ask_user. Only ask_user is forwarded.
    let resp = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m", "stream": true,
            "messages": [{"role": "user", "content": "hi"}],
            "tools": tools,
        }))
        .send()
        .await
        .unwrap();
    assert!(resp.status().is_success());
    let body = resp.text().await.unwrap();

    // Parse the forwarded app tool call from the SSE stream.
    let mut forwarded_id = None;
    let mut forwarded_names = Vec::new();
    let mut finish_reason = None;
    for line in body.lines() {
        let Some(data) = line.strip_prefix("data: ") else {
            continue;
        };
        if data == "[DONE]" {
            continue;
        }
        let v: serde_json::Value = serde_json::from_str(data).unwrap();
        if let Some(calls) = v["choices"][0]["delta"]["tool_calls"].as_array() {
            for c in calls {
                forwarded_names.push(c["function"]["name"].as_str().unwrap().to_string());
                forwarded_id = c["id"].as_str().map(String::from);
            }
        }
        if let Some(r) = v["choices"][0]["finish_reason"].as_str() {
            finish_reason = Some(r.to_string());
        }
    }
    assert_eq!(
        forwarded_names,
        vec!["ask_user".to_string()],
        "only the app tool is forwarded; calculator stays server-side"
    );
    assert_eq!(finish_reason.as_deref(), Some("tool_calls"));
    let call_id = forwarded_id.expect("forwarded app call carries an id");

    // Turn 2: the app answers ask_user and re-sends. The orchestrator must resume
    // from the held history (which already contains the calculator result).
    let resp = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m", "stream": true,
            "messages": [
                {"role": "user", "content": "hi"},
                {"role": "assistant", "content": serde_json::Value::Null, "tool_calls": [
                    {"id": call_id, "type": "function",
                     "function": {"name": "ask_user", "arguments": "{}"}}
                ]},
                {"role": "tool", "tool_call_id": call_id, "name": "ask_user", "content": "option A"},
            ],
            "tools": tools,
        }))
        .send()
        .await
        .unwrap();
    assert!(resp.status().is_success());
    let body = resp.text().await.unwrap();
    let mut content = String::new();
    for line in body.lines() {
        let Some(data) = line.strip_prefix("data: ") else {
            continue;
        };
        if data == "[DONE]" {
            continue;
        }
        let v: serde_json::Value = serde_json::from_str(data).unwrap();
        if let Some(c) = v["choices"][0]["delta"]["content"].as_str() {
            content.push_str(c);
        }
    }
    assert_eq!(
        content, "Hello world",
        "the resumed turn streams a final answer"
    );

    // The resumed upstream resolution request must carry BOTH the held server
    // tool result (calculator) and the app's answer — proof the server work was
    // preserved across the turn boundary rather than dropped or re-run.
    // Native Ollama carries a tool result's function name in `tool_name`.
    let requests = requests.lock().await;
    let resumed = requests
        .iter()
        .find(|r| {
            r["messages"]
                .as_array()
                .is_some_and(|ms| ms.iter().any(|m| m["tool_name"] == "calculator"))
        })
        .expect("a resumed upstream request includes the held calculator result");
    let tool_names: Vec<&str> = resumed["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["role"] == "tool")
        .map(|m| m["tool_name"].as_str().unwrap_or(""))
        .collect();
    assert!(
        tool_names.contains(&"calculator"),
        "held calculator result is replayed upstream: {tool_names:?}"
    );
    assert!(
        tool_names.contains(&"ask_user"),
        "the app's answer is appended: {tool_names:?}"
    );
}

#[tokio::test]
async fn detects_openai_compatible_upstream_when_tags_absent() {
    let openai = spawn(mock_openai_compatible()).await;
    let mut cfg = test_config(&openai);
    cfg.models = vec![];
    let upstreams = phantasm_orchestrator::detect_upstreams(&cfg, &reqwest::Client::new()).await;

    let primary = upstreams.primary();
    assert_eq!(primary.kind, UpstreamKind::OpenAICompatible);
    assert_eq!(primary.backend.kind(), primary.kind);
    assert_eq!(primary.models(), ["m".to_string()]);
}

#[tokio::test]
async fn detects_openai_compatible_upstream_when_tags_returns_json_error() {
    let openai = spawn(mock_openai_compatible_with_json_tags_error()).await;
    let mut cfg = test_config(&openai);
    cfg.models = vec![];
    let upstreams = phantasm_orchestrator::detect_upstreams(&cfg, &reqwest::Client::new()).await;

    let primary = upstreams.primary();
    assert_eq!(primary.kind, UpstreamKind::OpenAICompatible);
    assert_eq!(primary.backend.kind(), primary.kind);
    assert_eq!(primary.models(), ["m".to_string()]);
}

#[tokio::test]
async fn explicit_openai_compatible_upstream_skips_native_ollama_probe() {
    let openai = spawn(mock_openai_compatible()).await;
    let mut cfg = test_config(&openai);
    cfg.models = vec![];
    cfg.upstream_kind = Some(UpstreamKind::OpenAICompatible);
    let upstreams = phantasm_orchestrator::detect_upstreams(&cfg, &reqwest::Client::new()).await;

    let primary = upstreams.primary();
    assert_eq!(primary.kind, UpstreamKind::OpenAICompatible);
    assert_eq!(primary.backend.kind(), primary.kind);
    assert_eq!(primary.models(), ["m".to_string()]);
}

#[tokio::test]
async fn explicit_native_ollama_upstream_does_not_fallback_to_openai_compatible() {
    let openai = spawn(mock_openai_compatible()).await;
    let mut cfg = test_config(&openai);
    cfg.models = vec![];
    cfg.upstream_kind = Some(UpstreamKind::NativeOllama);
    let upstreams = phantasm_orchestrator::detect_upstreams(&cfg, &reqwest::Client::new()).await;

    let primary = upstreams.primary();
    assert_eq!(primary.kind, UpstreamKind::NativeOllama);
    assert_eq!(primary.backend.kind(), primary.kind);
    assert!(primary.models().is_empty());
}

#[tokio::test]
async fn native_capabilities_omit_metadata_when_show_errors() {
    let ollama = spawn(mock_ollama_show_error()).await;
    let mut cfg = test_config(&ollama);
    cfg.models = vec![];
    let http = reqwest::Client::new();
    let upstreams = phantasm_orchestrator::detect_upstreams(&cfg, &http).await;

    let capabilities = probe_capabilities(&cfg, &http, &upstreams, true).await;

    assert_eq!(capabilities.models.len(), 1);
    assert_eq!(capabilities.models[0].id, "m");
    assert!(
        capabilities.models[0].capabilities.is_none(),
        "failed /api/show metadata should be unknown, not known-unsupported"
    );
    assert_eq!(capabilities.models[0].context_length, None);
}

#[tokio::test]
async fn capability_refresh_uses_fixed_backend_kind() {
    let openai = spawn(mock_openai_compatible()).await;
    let mut cfg = test_config(&openai);
    cfg.models = vec![];
    let http = reqwest::Client::new();
    let spec = &cfg.upstream_specs()[0];
    let native = UpstreamChatBackend::from_spec(UpstreamKind::NativeOllama, http.clone(), spec);
    let upstreams = UpstreamSet::new(vec![UpstreamEntry::new(
        spec.name.clone(),
        UpstreamKind::NativeOllama,
        spec.base.clone(),
        native,
        4,
        vec![],
        vec![],
    )]);

    let capabilities = probe_capabilities(&cfg, &http, &upstreams, false).await;

    assert!(
        capabilities.models.is_empty(),
        "fixed native refresh must not redetect /v1/models from the same base URL"
    );
}

/// A second OpenAI-compatible mock standing in for vLLM: it serves one model
/// ("big") and streams distinct content, so a response proves which upstream a
/// chat was routed to.
fn mock_vllm_big_model() -> Router {
    Router::new()
        .route(
            "/v1/chat/completions",
            post(|body: axum::extract::Json<serde_json::Value>| async move {
                let streaming = body.0.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
                if streaming {
                    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"vllm\"},\"finish_reason\":null}]}\n\n\
                                data: {\"choices\":[{\"delta\":{\"content\":\" says hi\"},\"finish_reason\":null}]}\n\n\
                                data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n\
                                data: [DONE]\n\n";
                    ([(CONTENT_TYPE, "text/event-stream")], body).into_response()
                } else {
                    axum::Json(serde_json::json!({
                        "choices": [{
                            "message": { "role": "assistant", "content": "vllm says hi" },
                            "finish_reason": "stop"
                        }]
                    }))
                    .into_response()
                }
            }),
        )
        .route(
            "/v1/models",
            get(|| async { axum::Json(serde_json::json!({"data":[{"id":"big"}]})) }),
        )
}

/// End-to-end multi-upstream flow: an Ollama-style default upstream plus a
/// named vLLM-style extra. `/v1/models` advertises the union, and chats route
/// to whichever upstream serves the requested model (unknown ids fall back to
/// the default upstream).
#[tokio::test]
async fn multiple_upstreams_union_models_and_route_by_model() {
    let ollama = spawn(mock_ollama()).await;
    let vllm = spawn(mock_vllm_big_model()).await;

    let mut cfg = test_config(&ollama);
    cfg.models = vec![]; // default upstream's list comes from its /api/tags probe
    cfg.extra_upstreams = vec![phantasm_orchestrator::config::UpstreamSpec {
        name: "vllm".into(),
        kind: Some(UpstreamKind::OpenAICompatible),
        base: vllm.parse().unwrap(),
        api_key: None,
        thinking_hint: true,
        models: vec![], // probed from its /v1/models
        concurrency: Some(2),
    }];

    let http = phantasm_orchestrator::build_http_client().unwrap();
    let upstreams = phantasm_orchestrator::detect_upstreams(&cfg, &http).await;
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(probe_capabilities(&cfg, &http, &upstreams, true).await);
    let state =
        phantasm_orchestrator::build_state_with_upstreams(cfg, capabilities, http, upstreams);
    let base = spawn(routes::router(state)).await;

    // The advertised model list is the union across upstreams.
    let resp = reqwest::Client::new()
        .get(format!("{base}/v1/models"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send()
        .await
        .unwrap();
    assert!(resp.status().is_success());
    let body: serde_json::Value = resp.json().await.unwrap();
    let ids: Vec<&str> = body["data"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap())
        .collect();
    assert!(
        ids.contains(&"m"),
        "default upstream's model advertised: {ids:?}"
    );
    assert!(
        ids.contains(&"big"),
        "extra upstream's model advertised: {ids:?}"
    );

    let chat = |model: &'static str| {
        let base = base.clone();
        async move {
            let resp = reqwest::Client::new()
                .post(format!("{base}/v1/chat/completions"))
                .header("Authorization", format!("Bearer {TOKEN}"))
                .json(&serde_json::json!({
                    "model": model,
                    "stream": false,
                    "messages": [{"role": "user", "content": "hi"}],
                }))
                .send()
                .await
                .unwrap();
            assert!(resp.status().is_success(), "chat with {model} failed");
            let body: serde_json::Value = resp.json().await.unwrap();
            body["choices"][0]["message"]["content"]
                .as_str()
                .unwrap()
                .to_string()
        }
    };

    assert_eq!(
        chat("big").await,
        "vllm says hi",
        "big routes to the vllm upstream"
    );
    assert_eq!(
        chat("m").await,
        "Hello world",
        "m routes to the default upstream"
    );
    assert_eq!(
        chat("nope").await,
        "Hello world",
        "unknown models fall back to the default upstream"
    );

    // The dashboard reports one health row per upstream, in routing order.
    let resp = reqwest::Client::new()
        .get(format!("{base}/dashboard/data"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send()
        .await
        .unwrap();
    assert!(resp.status().is_success());
    let body: serde_json::Value = resp.json().await.unwrap();
    let rows = body["upstreams"].as_array().unwrap();
    assert_eq!(rows.len(), 2, "one row per upstream: {rows:?}");
    assert_eq!(rows[0]["name"], "default");
    assert_eq!(rows[0]["kind"], "ollama");
    assert_eq!(rows[0]["reachable"], true);
    assert_eq!(rows[1]["name"], "vllm");
    assert_eq!(rows[1]["kind"], "openai");
    assert_eq!(rows[1]["reachable"], true);
    assert_eq!(rows[1]["max_concurrency"], 2);
    assert_eq!(rows[1]["inflight"], 0);
    assert_eq!(rows[1]["models"], 1);
}

#[tokio::test]
async fn plain_chat_streams_tokens() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "stream": true,
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let body = resp.text().await.unwrap();

    // Concatenate the content deltas across all SSE chunks.
    let mut content = String::new();
    let mut saw_done = false;
    let mut saw_finish = false;
    for line in body.lines() {
        let Some(data) = line.strip_prefix("data: ") else {
            continue;
        };
        if data == "[DONE]" {
            saw_done = true;
            continue;
        }
        let v: serde_json::Value = serde_json::from_str(data).unwrap();
        if let Some(c) = v["choices"][0]["delta"]["content"].as_str() {
            content.push_str(c);
        }
        if v["choices"][0]["finish_reason"].as_str() == Some("stop") {
            saw_finish = true;
        }
    }
    assert_eq!(content, "Hello world");
    assert!(saw_finish, "expected a finish_reason:stop chunk");
    assert!(saw_done, "expected a [DONE] sentinel");
}

/// Concatenate the `delta.content` across an SSE body's chunks.
fn sse_content(body: &str) -> String {
    let mut content = String::new();
    for line in body.lines() {
        let Some(data) = line.strip_prefix("data: ") else {
            continue;
        };
        if data == "[DONE]" {
            continue;
        }
        let v: serde_json::Value = serde_json::from_str(data).unwrap();
        if let Some(c) = v["choices"][0]["delta"]["content"].as_str() {
            content.push_str(c);
        }
    }
    content
}

/// A streaming turn started with an `Idempotency-Key` is buffered server-side, so
/// a reconnect with the same key (what the app does after backgrounding) replays
/// the completed turn in full rather than re-running it upstream.
#[tokio::test]
async fn resumable_turn_replays_on_reconnect_without_rerunning() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let ollama = spawn(mock_ollama_recording(requests.clone())).await;
    let base = spawn_orchestrator(&ollama).await;
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "model": "m",
        "stream": true,
        "messages": [{"role": "user", "content": "hi"}],
    });

    // First connection: streams to completion and buffers the turn.
    let resp = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .header("Idempotency-Key", "turn-123")
        .json(&body)
        .send()
        .await
        .unwrap();
    assert!(resp.status().is_success());
    let first = resp.text().await.unwrap();
    assert_eq!(sse_content(&first), "Hello world");
    assert!(
        first.lines().any(|l| l.starts_with("id: 0")),
        "events carry monotonic SSE id: lines for Last-Event-ID resume"
    );

    // Reconnect with the SAME key: the buffered turn is replayed verbatim.
    let resp = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .header("Idempotency-Key", "turn-123")
        .json(&body)
        .send()
        .await
        .unwrap();
    assert!(resp.status().is_success());
    let replay = resp.text().await.unwrap();
    assert_eq!(
        sse_content(&replay),
        "Hello world",
        "reconnect replays the buffered turn"
    );
    assert!(replay.lines().any(|l| l == "data: [DONE]"));

    // The upstream was hit exactly once: the replay served from the buffer, it
    // did not re-run the turn.
    assert_eq!(
        requests.lock().await.len(),
        1,
        "reconnect must not re-issue the turn upstream"
    );
}

/// Resume with `Last-Event-ID` replays only the tail past that cursor.
#[tokio::test]
async fn resumable_turn_resumes_from_last_event_id() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "model": "m",
        "stream": true,
        "messages": [{"role": "user", "content": "hi"}],
    });

    // Run the turn to completion so the full log is buffered.
    let first = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .header("Idempotency-Key", "turn-xyz")
        .json(&body)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    // The first content delta is event id 0 ("Hello"); resume strictly after it.
    assert_eq!(sse_content(&first), "Hello world");

    let resumed = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .header("Idempotency-Key", "turn-xyz")
        .header("Last-Event-ID", "0")
        .json(&body)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    // Replaying past id 0 omits the first token, so only " world" remains.
    assert_eq!(
        sse_content(&resumed),
        " world",
        "Last-Event-ID skips already-delivered events"
    );
}

/// A resumable turn that ended in an upstream error logs only the Error event;
/// its WARNING/finish/[DONE] tail is synthesized per-stream. A client that
/// resumes with `Last-Event-ID` pointing at the Error event must still get a
/// terminating tail, not an empty stream that ends without finish or [DONE].
#[tokio::test]
async fn resumed_stream_past_error_still_terminates() {
    let openai = spawn(mock_openai_compatible_erroring()).await;
    let base = spawn_orchestrator_with_kind(&openai, UpstreamKind::OpenAICompatible).await;
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "model": "m",
        "stream": true,
        "messages": [{"role": "user", "content": "hi"}],
    });

    // First connection: the turn errors; the stream carries the warning tail.
    let first = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .header("Idempotency-Key", "turn-err")
        .json(&body)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(first.contains("WARNING:"), "error surfaced in-stream");

    // Resume from the Error event's id (the only logged event, id 0): the tail
    // must be re-synthesized so the resumed stream terminates.
    let resumed = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .header("Idempotency-Key", "turn-err")
        .header("Last-Event-ID", "0")
        .json(&body)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(
        resumed.contains("WARNING:"),
        "resumed stream re-synthesizes the warning tail: {resumed}"
    );
    let finish = resumed
        .lines()
        .filter_map(|l| l.strip_prefix("data: "))
        .any(|d| {
            d != "[DONE]"
                && serde_json::from_str::<serde_json::Value>(d)
                    .is_ok_and(|v| v["choices"][0]["finish_reason"] == "stop")
        });
    assert!(finish, "resumed stream carries a finish chunk: {resumed}");
    assert!(
        resumed.lines().any(|l| l == "data: [DONE]"),
        "resumed stream terminates with [DONE]: {resumed}"
    );
}

/// `POST /v1/chat/cancel` drops a buffered turn, so a later reconnect with the
/// same key starts fresh (re-runs upstream) rather than replaying. An unknown id
/// is a no-op `204`.
#[tokio::test]
async fn cancel_drops_turn_so_reconnect_reruns() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let ollama = spawn(mock_ollama_recording(requests.clone())).await;
    let base = spawn_orchestrator(&ollama).await;
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "model": "m",
        "stream": true,
        "messages": [{"role": "user", "content": "hi"}],
    });

    // Run + buffer the turn (1 upstream hit).
    client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .header("Idempotency-Key", "turn-c")
        .json(&body)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert_eq!(requests.lock().await.len(), 1);

    // Cancelling an unknown id is a no-op 204.
    let unknown = client
        .post(format!("{base}/v1/chat/cancel"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({ "turn_id": "nope" }))
        .send()
        .await
        .unwrap();
    assert_eq!(unknown.status(), reqwest::StatusCode::NO_CONTENT);

    // Cancel the real turn.
    let cancelled = client
        .post(format!("{base}/v1/chat/cancel"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({ "turn_id": "turn-c" }))
        .send()
        .await
        .unwrap();
    assert_eq!(cancelled.status(), reqwest::StatusCode::NO_CONTENT);

    // Reconnecting with the same key now re-runs the turn (2 upstream hits),
    // proving the buffered turn was dropped.
    client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .header("Idempotency-Key", "turn-c")
        .json(&body)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert_eq!(
        requests.lock().await.len(),
        2,
        "cancel removed the buffer, so the reconnect re-ran the turn"
    );
}

/// The cancel endpoint is bearer-gated like the rest of the chat surface.
#[tokio::test]
async fn cancel_requires_auth() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;
    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/cancel"))
        .json(&serde_json::json!({ "turn_id": "x" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), reqwest::StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn regular_native_chat_omits_keep_alive() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let ollama = spawn(mock_ollama_recording(requests.clone())).await;
    let base = spawn_orchestrator(&ollama).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "stream": false,
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let requests = requests.lock().await;
    assert_eq!(requests.len(), 1);
    assert!(requests[0].get("keep_alive").is_none());
}

#[tokio::test]
async fn openai_compatible_upstream_streams_tokens() {
    let openai = spawn(mock_openai_compatible()).await;
    let base = spawn_orchestrator_with_kind(&openai, UpstreamKind::OpenAICompatible).await;
    let client = reqwest::Client::new();

    let resp = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "stream": true,
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let body = resp.text().await.unwrap();
    let mut content = String::new();
    let mut saw_done = false;
    for line in body.lines() {
        let Some(data) = line.strip_prefix("data: ") else {
            continue;
        };
        if data == "[DONE]" {
            saw_done = true;
            continue;
        }
        let v: serde_json::Value = serde_json::from_str(data).unwrap();
        if let Some(c) = v["choices"][0]["delta"]["content"].as_str() {
            content.push_str(c);
        }
    }
    assert_eq!(content, "Hello world");
    assert!(saw_done, "expected a [DONE] sentinel");

    let mut metrics = String::new();
    for _ in 0..100 {
        let resp = client
            .get(format!("{base}/metrics"))
            .header("Authorization", format!("Bearer {TOKEN}"))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), reqwest::StatusCode::OK);
        metrics = resp.text().await.unwrap();
        if metrics.contains("phantasm_completion_tokens_total{model=\"m\"} 2") {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(
        metrics.contains("phantasm_prompt_tokens_total{model=\"m\"} 7"),
        "{metrics}"
    );
    assert!(
        metrics.contains("phantasm_completion_tokens_total{model=\"m\"} 2"),
        "{metrics}"
    );
    assert!(
        metrics.contains("phantasm_generation_tokens_per_second_count{model=\"m\"} 1"),
        "{metrics}"
    );
}

#[tokio::test]
async fn openai_compatible_stream_retries_without_usage_for_strict_servers() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let openai = spawn(mock_openai_compatible_strict_stream_options(
        requests.clone(),
    ))
    .await;
    let base = spawn_orchestrator_with_kind(&openai, UpstreamKind::OpenAICompatible).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "stream": true,
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let body = resp.text().await.unwrap();
    assert!(body.contains("strict"), "{body}");
    let requests = requests.lock().await;
    assert_eq!(requests.len(), 2);
    assert!(requests[0].get("stream_options").is_some());
    assert!(requests[1].get("stream_options").is_none());
}

#[tokio::test]
async fn openai_compatible_upstream_runs_server_tool_loop() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let openai = spawn(mock_openai_compatible_tool_call(requests.clone())).await;
    let base =
        spawn_orchestrator_with_calculator_kind(&openai, UpstreamKind::OpenAICompatible).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "stream": true,
            "tool_choice": "required",
            "messages": [{"role": "user", "content": "what is 1+1?"}],
        }))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let body = resp.text().await.unwrap();
    let mut content = String::new();
    for line in body.lines() {
        let Some(data) = line.strip_prefix("data: ") else {
            continue;
        };
        if data == "[DONE]" {
            continue;
        }
        let v: serde_json::Value = serde_json::from_str(data).unwrap();
        if let Some(c) = v["choices"][0]["delta"]["content"].as_str() {
            content.push_str(c);
        }
    }
    assert_eq!(content, "Hello world");

    let requests = requests.lock().await;
    let resolution = requests
        .iter()
        .find(|r| r["tools"].as_array().is_some_and(|tools| !tools.is_empty()))
        .expect(
            "expected the non-streaming OpenAI-compatible tool-resolution call to include tools",
        );
    assert_eq!(
        resolution["tool_choice"], "required",
        "expected downstream tool_choice to be forwarded during tool resolution"
    );
    assert!(
        requests.iter().any(|r| {
            r["messages"]
                .as_array()
                .is_some_and(|ms| ms.iter().any(|m| m["role"] == "tool"))
        }),
        "expected the resumed OpenAI-compatible call to include the calculator tool result"
    );
    let resumed = requests
        .iter()
        .find(|r| {
            r["messages"]
                .as_array()
                .is_some_and(|ms| ms.iter().any(|m| m["role"] == "tool"))
        })
        .expect("resumed request");
    let tool_message = resumed["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["role"] == "tool")
        .expect("tool result message");
    assert_eq!(tool_message["tool_call_id"], "call_calc");
    assert!(tool_message.get("name").is_none());
    assert!(
        requests
            .iter()
            .filter(|r| r["stream"].as_bool() == Some(true))
            .all(|r| r.get("tools").is_none() && r.get("tool_choice").is_none()),
        "expected final OpenAI-compatible stream requests to omit tools and tool_choice"
    );
    assert!(
        requests
            .iter()
            .filter(|r| r["messages"]
                .as_array()
                .is_some_and(|ms| { ms.iter().any(|m| m["role"] == "tool") }))
            .all(|r| r.get("tool_choice").is_none()),
        "expected resumed post-tool OpenAI-compatible calls to omit tool_choice"
    );
}

#[tokio::test]
async fn openai_compatible_upstream_error_surfaces_as_bad_gateway() {
    let openai = spawn(mock_openai_compatible_erroring()).await;
    let base = spawn_orchestrator_with_kind(&openai, UpstreamKind::OpenAICompatible).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "stream": false,
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .send()
        .await
        .unwrap();

    // UpstreamError maps to 502, and the upstream status + detail ride through.
    assert_eq!(resp.status().as_u16(), 502);
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["error"]["type"], "upstream_error");
    let message = v["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("500") && message.contains("upstream boom"),
        "expected upstream status + detail in error message, got: {message}"
    );
}

#[tokio::test]
async fn non_streaming_returns_completion() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "stream": false,
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["object"], "chat.completion");
    assert_eq!(v["choices"][0]["message"]["content"], "Hello world");
}

#[tokio::test]
async fn warm_loads_native_ollama_model() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let ollama = spawn(mock_ollama_recording(requests.clone())).await;
    let base = spawn_orchestrator(&ollama).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/warm"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({ "model": "m" }))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["warmed"], true);
    assert_eq!(v["model"], "m");

    let requests = requests.lock().await;
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].get("keep_alive").and_then(|v| v.as_str()),
        Some("30m")
    );
    assert_eq!(requests[0]["messages"], serde_json::json!([]));
}

#[tokio::test]
async fn warm_is_noop_for_openai_compatible_upstream() {
    let openai = spawn(mock_openai_compatible()).await;
    let base = spawn_orchestrator_with_kind(&openai, UpstreamKind::OpenAICompatible).await;

    // No model given → falls back to the configured default; not an error.
    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/warm"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({}))
        .send()
        .await
        .unwrap();

    assert!(resp.status().is_success());
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["warmed"], false);
    assert_eq!(v["model"], "m");
}

#[tokio::test]
async fn missing_token_is_rejected() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;

    let resp = reqwest::Client::new()
        .post(format!("{base}/v1/chat/completions"))
        .json(&serde_json::json!({"messages": [{"role":"user","content":"hi"}]}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), reqwest::StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn healthz_is_public_liveness_check() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;

    let resp = reqwest::Client::new()
        .get(format!("{base}/healthz"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), reqwest::StatusCode::OK);
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["status"], "ok");
    assert!(v["version"].as_str().is_some_and(|s| !s.is_empty()));
}

#[tokio::test]
async fn auth_disabled_accepts_unauthenticated_requests() {
    let ollama = spawn(mock_ollama()).await;
    let mut cfg = test_config(&ollama);
    cfg.auth_token = None; // auth disabled
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, UpstreamKind::NativeOllama);
    let base = spawn(routes::router(state)).await;

    // No Authorization header => still served (200), not 401.
    let resp = reqwest::Client::new()
        .get(format!("{base}/v1/capabilities"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), reqwest::StatusCode::OK);
}

#[tokio::test]
async fn capabilities_requires_auth_and_reports_models() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;
    let client = reqwest::Client::new();

    let unauthorized = client
        .get(format!("{base}/v1/capabilities"))
        .send()
        .await
        .unwrap();
    assert_eq!(unauthorized.status(), reqwest::StatusCode::UNAUTHORIZED);

    let ok = client
        .get(format!("{base}/v1/capabilities"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send()
        .await
        .unwrap();
    assert!(ok.status().is_success());
    let v: serde_json::Value = ok.json().await.unwrap();
    assert_eq!(v["models"][0]["id"], "m");
    assert_eq!(v["models"][0]["capabilities"]["completion"], true);
    assert_eq!(v["models"][0]["capabilities"]["vision"], false);
    assert_eq!(v["models"][0]["capabilities"]["audio"], false);
    assert_eq!(v["models"][0]["capabilities"]["tools"], false);
    assert_eq!(v["models"][0]["capabilities"]["insert"], false);
    assert_eq!(v["models"][0]["capabilities"]["thinking"], false);
    assert_eq!(v["models"][0]["capabilities"]["embedding"], false);
    assert_eq!(v["models"][0]["context_length"], 4096);
    assert_eq!(v["tool_selectors"], serde_json::json!([]));
    assert!(v.get("chat").is_none());
    assert!(v.get("streaming").is_none());
    assert!(v.get("tools").is_none());
}

/// Spawn the orchestrator with a CORS allow-list configured.
async fn spawn_orchestrator_with_cors(upstream_base: &str, origins: Vec<String>) -> String {
    let mut cfg = test_config(upstream_base);
    cfg.cors_allowed_origins = origins;
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, UpstreamKind::NativeOllama);
    spawn(routes::router(state)).await
}

/// With no allow-list (the default), CORS is off: a browser preflight gets no
/// `Access-Control-Allow-Origin`, so the browser blocks the cross-origin call.
#[tokio::test]
async fn cors_disabled_by_default() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;

    let resp = reqwest::Client::new()
        .request(
            reqwest::Method::OPTIONS,
            format!("{base}/v1/chat/completions"),
        )
        .header("Origin", "https://chat.example")
        .header("Access-Control-Request-Method", "POST")
        .send()
        .await
        .unwrap();
    assert!(resp.headers().get("access-control-allow-origin").is_none());
}

/// With an allow-list, an in-list origin is reflected and the preflight is
/// answered without bearer auth (preflights carry no `Authorization`).
#[tokio::test]
async fn cors_allows_configured_origin() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator_with_cors(&ollama, vec!["https://chat.example".into()]).await;

    let preflight = reqwest::Client::new()
        .request(
            reqwest::Method::OPTIONS,
            format!("{base}/v1/chat/completions"),
        )
        .header("Origin", "https://chat.example")
        .header("Access-Control-Request-Method", "POST")
        .send()
        .await
        .unwrap();
    assert!(preflight.status().is_success());
    assert_eq!(
        preflight
            .headers()
            .get("access-control-allow-origin")
            .unwrap(),
        "https://chat.example"
    );

    // A different origin is not reflected back.
    let other = reqwest::Client::new()
        .request(
            reqwest::Method::OPTIONS,
            format!("{base}/v1/chat/completions"),
        )
        .header("Origin", "https://evil.example")
        .header("Access-Control-Request-Method", "POST")
        .send()
        .await
        .unwrap();
    assert!(other.headers().get("access-control-allow-origin").is_none());
}

/// Spawn the orchestrator with a server-hosted image store rooted at `dir`. The
/// store's signing key is the server auth token, so a `BlobStore` the test
/// builds against the same dir + token mints URLs the server will accept.
async fn spawn_orchestrator_with_images(upstream_base: &str, dir: std::path::PathBuf) -> String {
    let mut cfg = test_config(upstream_base);
    cfg.image_store_dir = Some(dir);
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, UpstreamKind::NativeOllama);
    spawn(routes::router(state)).await
}

const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

#[tokio::test]
async fn image_fetch_is_signed_and_auth_exempt() {
    use phantasm_orchestrator::images::BlobStore;

    let ollama = spawn(mock_ollama()).await;
    let tmp = tempfile::tempdir().unwrap();
    // A store sharing the server's dir + signing key (the auth token) to seed a
    // blob and mint matching signed URLs.
    let seeder = BlobStore::new(
        tmp.path().to_path_buf(),
        TOKEN,
        3600,
        16 * 1024 * 1024,
        None,
    )
    .unwrap();
    let id = seeder.put(PNG).await.unwrap();
    let signed = seeder.signed_ref(&id); // "/v1/files/<id>/content?exp=..&sig=.."

    let base = spawn_orchestrator_with_images(&ollama, tmp.path().to_path_buf()).await;
    let client = reqwest::Client::new();

    // Valid signature, NO Authorization header => served.
    let ok = client.get(format!("{base}{signed}")).send().await.unwrap();
    assert!(ok.status().is_success());
    assert_eq!(ok.headers()[CONTENT_TYPE], "image/png");
    assert_eq!(ok.bytes().await.unwrap().as_ref(), PNG);

    // Tampered signature => forbidden.
    let bad = signed.replace("sig=", "sig=zzz");
    let forbidden = client.get(format!("{base}{bad}")).send().await.unwrap();
    assert_eq!(forbidden.status(), reqwest::StatusCode::FORBIDDEN);

    // Missing signature params => 400 (Query extractor rejects).
    let no_sig = client
        .get(format!("{base}/v1/files/{id}/content"))
        .send()
        .await
        .unwrap();
    assert_eq!(no_sig.status(), reqwest::StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn image_delete_requires_auth_then_removes() {
    use phantasm_orchestrator::images::BlobStore;

    let ollama = spawn(mock_ollama()).await;
    let tmp = tempfile::tempdir().unwrap();
    let seeder = BlobStore::new(
        tmp.path().to_path_buf(),
        TOKEN,
        3600,
        16 * 1024 * 1024,
        None,
    )
    .unwrap();
    let id = seeder.put(PNG).await.unwrap();
    let signed = seeder.signed_ref(&id);

    let base = spawn_orchestrator_with_images(&ollama, tmp.path().to_path_buf()).await;
    let client = reqwest::Client::new();

    // DELETE without bearer => 401.
    let unauthed = client
        .delete(format!("{base}/v1/files/{id}"))
        .send()
        .await
        .unwrap();
    assert_eq!(unauthed.status(), reqwest::StatusCode::UNAUTHORIZED);

    // DELETE with bearer => 204, and the blob is gone afterward (404 even with a
    // still-valid signature).
    let deleted = client
        .delete(format!("{base}/v1/files/{id}"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send()
        .await
        .unwrap();
    assert_eq!(deleted.status(), reqwest::StatusCode::NO_CONTENT);

    let gone = client.get(format!("{base}{signed}")).send().await.unwrap();
    assert_eq!(gone.status(), reqwest::StatusCode::NOT_FOUND);
}

// ---- Observability: /metrics + dashboard -----------------------------------

/// Drive one streaming chat turn and return the concatenated streamed content.
async fn drive_streaming_turn(client: &reqwest::Client, base: &str) -> String {
    let resp = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .json(&serde_json::json!({
            "model": "m", "stream": true,
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .send()
        .await
        .unwrap();
    assert!(resp.status().is_success());
    resp.text().await.unwrap()
}

/// `GET /metrics` is bearer-gated, serves the Prometheus text format, and
/// reflects a completed turn's per-model counters — including the token counts
/// parsed from the mock's final NDJSON chunk.
#[tokio::test]
async fn metrics_endpoint_is_gated_and_reports_turns_and_tokens() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator(&ollama).await;
    let client = reqwest::Client::new();

    let bare = client.get(format!("{base}/metrics")).send().await.unwrap();
    assert_eq!(bare.status(), reqwest::StatusCode::UNAUTHORIZED);

    drive_streaming_turn(&client, &base).await;

    // Turn completion is recorded by a detached forwarder task after the SSE
    // body ends, so poll briefly rather than assert immediately.
    let mut body = String::new();
    for _ in 0..100 {
        let resp = client
            .get(format!("{base}/metrics"))
            .header("Authorization", format!("Bearer {TOKEN}"))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), reqwest::StatusCode::OK);
        assert!(resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|ct| ct.starts_with("text/plain")));
        body = resp.text().await.unwrap();
        if body.contains("phantasm_turns_completed_total{model=\"m\"} 1") {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(
        body.contains("phantasm_turns_started_total{model=\"m\"} 1"),
        "{body}"
    );
    assert!(
        body.contains("phantasm_turns_completed_total{model=\"m\"} 1"),
        "{body}"
    );
    assert!(
        body.contains("phantasm_turns_plain_total{model=\"m\"} 1"),
        "{body}"
    );
    assert!(
        body.contains("phantasm_prompt_tokens_total{model=\"m\"} 7"),
        "{body}"
    );
    assert!(
        body.contains("phantasm_completion_tokens_total{model=\"m\"} 30"),
        "{body}"
    );
    assert!(
        body.contains("# TYPE phantasm_turn_duration_seconds histogram"),
        "{body}"
    );
    assert!(body.contains("phantasm_build_info"), "{body}");
}

/// The dashboard page is public (it carries no data); the data endpoint is
/// bearer-gated, reports the turn from the SQLite history, honors the model
/// filter, and keeps the live-probe fields null-safe when the upstream lacks
/// `/api/ps`.
#[tokio::test]
async fn dashboard_page_public_and_data_gated_with_history() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("metrics.sqlite");
    let images = dir.path().join("images");
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator_with_cfg(&ollama, |cfg| {
        cfg.metrics_db = Some(db.clone());
        cfg.image_store_dir = Some(images.clone());
    })
    .await;
    let client = reqwest::Client::new();

    let page = client
        .get(format!("{base}/dashboard"))
        .send()
        .await
        .unwrap();
    assert_eq!(page.status(), reqwest::StatusCode::OK);
    let ct = page
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(ct.starts_with("text/html"), "{ct}");
    let html = page.text().await.unwrap();
    assert!(html.contains("Phantasm"));
    assert!(
        !html.contains(TOKEN),
        "the public page must not embed the token"
    );

    let bare = client
        .get(format!("{base}/dashboard/data"))
        .send()
        .await
        .unwrap();
    assert_eq!(bare.status(), reqwest::StatusCode::UNAUTHORIZED);

    drive_streaming_turn(&client, &base).await;

    // The turn row lands via forwarder task -> store writer thread; poll.
    let mut data = serde_json::Value::Null;
    for _ in 0..200 {
        let resp = client
            .get(format!("{base}/dashboard/data?range=3h"))
            .header("Authorization", format!("Bearer {TOKEN}"))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), reqwest::StatusCode::OK);
        data = resp.json().await.unwrap();
        if data["history"]["outcomes"]["completed"].as_u64() == Some(1) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(data["history"]["outcomes"]["completed"], 1, "{data}");
    assert_eq!(data["history"]["outcomes"]["plain"], 1, "{data}");
    assert_eq!(data["history"]["tokens"]["prompt"], 7, "{data}");
    assert_eq!(data["history"]["models"][0]["model"], "m", "{data}");
    assert!(
        data["history"]["latency"]["p50_ms"].is_u64()
            || data["history"]["latency"]["p50_ms"].is_number(),
        "{data}"
    );
    // The mock serves no /api/ps: the panel reports unreachable, not an error.
    assert_eq!(data["ollama"]["reachable"], false, "{data}");
    assert!(data["host"].is_object(), "{data}");
    // The image store is enabled (empty) and its filesystem has headroom.
    assert_eq!(data["image_store"]["files"], 0, "{data}");
    assert_eq!(data["image_store"]["bytes"], 0, "{data}");
    assert!(
        data["disk"]["total_bytes"].as_u64().unwrap_or(0) > 0,
        "{data}"
    );
    assert!(data["disk"]["available_bytes"].is_u64(), "{data}");

    // The model filter scopes the range sections but not the per-model summary.
    let filtered: serde_json::Value = client
        .get(format!("{base}/dashboard/data?range=3h&model=nope"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        filtered["history"]["outcomes"]["completed"], 0,
        "{filtered}"
    );
    assert_eq!(filtered["history"]["models"][0]["model"], "m", "{filtered}");
}

/// `PHANTASM_DASHBOARD=false` removes both dashboard routes entirely; /metrics
/// stays available (authed).
#[tokio::test]
async fn dashboard_disabled_removes_routes_but_keeps_metrics() {
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator_with_cfg(&ollama, |cfg| {
        cfg.dashboard_enabled = false;
    })
    .await;
    let client = reqwest::Client::new();

    let page = client
        .get(format!("{base}/dashboard"))
        .send()
        .await
        .unwrap();
    assert_eq!(page.status(), reqwest::StatusCode::NOT_FOUND);
    let data = client
        .get(format!("{base}/dashboard/data"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send()
        .await
        .unwrap();
    assert_eq!(data.status(), reqwest::StatusCode::NOT_FOUND);

    let metrics = client
        .get(format!("{base}/metrics"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send()
        .await
        .unwrap();
    assert_eq!(metrics.status(), reqwest::StatusCode::OK);
}

/// The SQLite history survives a full state rebuild (the restart story).
#[tokio::test]
async fn metrics_history_survives_restart() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("metrics.sqlite");
    let ollama = spawn(mock_ollama()).await;
    let client = reqwest::Client::new();

    let base = spawn_orchestrator_with_cfg(&ollama, |cfg| {
        cfg.metrics_db = Some(db.clone());
    })
    .await;
    drive_streaming_turn(&client, &base).await;
    // Wait until the row is durably visible before "restarting".
    for _ in 0..200 {
        let data: serde_json::Value = client
            .get(format!("{base}/dashboard/data"))
            .header("Authorization", format!("Bearer {TOKEN}"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        if data["history"]["outcomes"]["completed"].as_u64() == Some(1) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }

    // A second orchestrator over the same DB file sees the old turn.
    let base2 = spawn_orchestrator_with_cfg(&ollama, |cfg| {
        cfg.metrics_db = Some(db.clone());
    })
    .await;
    let data: serde_json::Value = client
        .get(format!("{base2}/dashboard/data"))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(data["history"]["outcomes"]["completed"], 1, "{data}");
}

/// With `PHANTASM_METRICS_TOKEN` set, the observability routes accept ONLY it
/// (the main API token stops working there), and it grants nothing on the
/// chat/API routes. Unset, they fall back to the main token (covered by
/// `metrics_endpoint_is_gated_and_reports_turns_and_tokens`).
#[tokio::test]
async fn metrics_token_is_separate_from_api_auth() {
    const METRICS_TOKEN: &str = "metrics-only-token";
    let ollama = spawn(mock_ollama()).await;
    let base = spawn_orchestrator_with_cfg(&ollama, |cfg| {
        cfg.metrics_token = Some(METRICS_TOKEN.into());
    })
    .await;
    let client = reqwest::Client::new();
    let get = |path: &str, tok: &str| {
        client
            .get(format!("{base}{path}"))
            .header("Authorization", format!("Bearer {tok}"))
            .send()
    };

    // Observability routes: metrics token works, the main API token does not.
    assert_eq!(get("/metrics", METRICS_TOKEN).await.unwrap().status(), 200);
    assert_eq!(get("/metrics", TOKEN).await.unwrap().status(), 401);
    assert_eq!(
        get("/dashboard/data", METRICS_TOKEN)
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(get("/dashboard/data", TOKEN).await.unwrap().status(), 401);

    // API routes: the metrics token opens nothing; the main token still works.
    assert_eq!(
        get("/v1/models", METRICS_TOKEN).await.unwrap().status(),
        401
    );
    assert_eq!(get("/v1/models", TOKEN).await.unwrap().status(), 200);
    let chat = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", format!("Bearer {METRICS_TOKEN}"))
        .json(&serde_json::json!({
            "model": "m",
            "messages": [{"role": "user", "content": "hi"}],
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(chat.status(), 401);
}
