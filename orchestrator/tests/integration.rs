//! End-to-end smoke tests: the real orchestrator router in front of a mock
//! Ollama (an in-process axum app serving NDJSON). No real backends required.

use std::sync::Arc;

use axum::http::header::CONTENT_TYPE;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::Router;
use phantasm_orchestrator::config::{Config, LogFormat};
use phantasm_orchestrator::ollama::UpstreamKind;
use phantasm_orchestrator::routes;
use phantasm_orchestrator::state::{CapabilitySnapshot, ToolFlags};

const TOKEN: &str = "test-token";

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
    Router::new()
        .route(
            "/api/chat",
            post(|body: axum::extract::Json<serde_json::Value>| async move {
                let streaming = body.0.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
                if streaming {
                    "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}\n\
                     {\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\" world\"},\"done\":true,\"done_reason\":\"stop\"}\n"
                } else {
                    "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello world\"},\"done\":true}"
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

fn test_config(ollama_base: &str) -> Config {
    Config {
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        auth_token: TOKEN.into(),
        ollama_base: ollama_base.parse().unwrap(),
        upstream_api_key: None,
        default_model: "m".into(),
        models: vec!["m".into()],
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
        comfy_max_image_bytes: 16 * 1024 * 1024,
        log_format: LogFormat::Text,
        log_content: false,
    }
}

async fn spawn_orchestrator(ollama_base: &str) -> String {
    spawn_orchestrator_with_kind(ollama_base, UpstreamKind::NativeOllama).await
}

async fn spawn_orchestrator_with_kind(ollama_base: &str, upstream_kind: UpstreamKind) -> String {
    let cfg = Arc::new(test_config(ollama_base));
    let capabilities = Arc::new(CapabilitySnapshot {
        version: "test".into(),
        chat: true,
        models: vec!["m".into()],
        vision_models: vec![],
        tools: ToolFlags {
            web_search: false,
            image_generation: false,
        },
        streaming: "sse",
    });
    let state = phantasm_orchestrator::build_state(cfg, capabilities, upstream_kind);
    spawn(routes::router(state)).await
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
    let ollama = spawn(mock_ollama()).await;
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
    assert_eq!(v["chat"], true);
    assert_eq!(v["streaming"], "sse");
    assert_eq!(v["models"][0], "m");
    assert_eq!(v["tools"]["web_search"], false);
}
