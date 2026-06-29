//! End-to-end smoke tests: the real orchestrator router in front of a mock
//! Ollama (an in-process axum app serving NDJSON). No real backends required.

use std::sync::Arc;

use axum::http::header::CONTENT_TYPE;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::Router;
use phantasm_orchestrator::config::{Config, LogFormat};
use phantasm_orchestrator::ollama::UpstreamKind;
use phantasm_orchestrator::routes;
use phantasm_orchestrator::state::{CapabilitySnapshot, ModelCapabilities, ModelInfo};
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
                        "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}\n\
                         {\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\" world\"},\"done\":true,\"done_reason\":\"stop\"}\n"
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
                    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n\
                                data: {\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish_reason\":null}]}\n\n\
                                data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n\
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

fn test_config(ollama_base: &str) -> Config {
    Config {
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        auth_token: Some(TOKEN.into()),
        cors_allowed_origins: vec![],
        ollama_base: ollama_base.parse().unwrap(),
        upstream_api_key: None,
        default_model: "m".into(),
        models: vec!["m".into()],
        max_tool_iters: 5,
        ollama_concurrency: 4,
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

async fn spawn_orchestrator(ollama_base: &str) -> String {
    spawn_orchestrator_with_kind(ollama_base, UpstreamKind::NativeOllama).await
}

async fn spawn_orchestrator_with_kind(ollama_base: &str, upstream_kind: UpstreamKind) -> String {
    let cfg = Arc::new(test_config(ollama_base));
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, upstream_kind);
    spawn(routes::router(state)).await
}

/// Like `spawn_orchestrator`, but with the `calculator` server tool enabled so
/// the mixed app+server tool-call flow has a real server tool to execute.
async fn spawn_orchestrator_with_calculator(ollama_base: &str) -> String {
    let mut cfg = test_config(ollama_base);
    cfg.calculator_enabled = true;
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, UpstreamKind::NativeOllama);
    spawn(routes::router(state)).await
}

/// Like `spawn_orchestrator`, but with the `code_exec` server tool enabled. The
/// runtime binary is intentionally bogus so the warm pool's container launches
/// fail fast — no real Docker/Podman is needed in CI. This exercises the wiring
/// and the non-fatal failure path (NFR-O6): the tool folds its error into the
/// `tool` message and the turn still completes.
async fn spawn_orchestrator_with_code_exec(ollama_base: &str) -> String {
    let mut cfg = test_config(ollama_base);
    cfg.code_exec_enabled = true;
    cfg.code_exec_runtime = "/nonexistent/phantasm-codeexec-runtime".into();
    cfg.code_exec_languages = vec!["python".into()];
    cfg.code_exec_pool_size = 1;
    let cfg = Arc::new(cfg);
    let capabilities = Arc::new(test_capabilities());
    let state = phantasm_orchestrator::build_state(cfg, capabilities, UpstreamKind::NativeOllama);
    spawn(routes::router(state)).await
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
    let cfg = test_config(&openai);
    let detection = phantasm_orchestrator::detect_upstream(&cfg, &reqwest::Client::new()).await;

    assert_eq!(detection.kind, UpstreamKind::OpenAICompatible);
    assert_eq!(detection.models, ["m".to_string()]);
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

    // OllamaError maps to 502, and the upstream status + detail ride through.
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
async fn spawn_orchestrator_with_cors(ollama_base: &str, origins: Vec<String>) -> String {
    let mut cfg = test_config(ollama_base);
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
async fn spawn_orchestrator_with_images(ollama_base: &str, dir: std::path::PathBuf) -> String {
    let mut cfg = test_config(ollama_base);
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
