//! Opt-in smoke tests against a real upstream model host.
//!
//! These are ignored by default because they require a running Ollama,
//! llama.cpp, or vLLM server and a local model. They deliberately assert only
//! protocol-level behavior through the orchestrator: model listing,
//! capabilities, non-streaming chat, streaming chat, and failure mapping.
//! Thinking and real model tool-calling are model/template-sensitive and are
//! gated behind explicit environment variables.

use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use phantasm_orchestrator::config::Config;
use phantasm_orchestrator::{
    build_state_with_upstreams, detect_upstreams, probe_capabilities, routes,
};
use reqwest::RequestBuilder;
use serde_json::Value;

async fn spawn(app: Router) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    format!("http://{addr}")
}

fn authed(req: RequestBuilder, token: &Option<String>) -> RequestBuilder {
    match token {
        Some(token) => req.bearer_auth(token),
        None => req,
    }
}

fn selected_model(cfg: &Config, detected_models: &[String]) -> String {
    std::env::var("UPSTREAM_DEFAULT_MODEL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| detected_models.first().cloned())
        .unwrap_or_else(|| cfg.default_model.clone())
}

struct RealHarness {
    base: String,
    client: reqwest::Client,
    auth_token: Option<String>,
    model: String,
}

impl RealHarness {
    async fn start(mut cfg: Config) -> Self {
        let auth_token = cfg.auth_token.clone();

        let probe_http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(10))
            .build()
            .expect("build probe client");
        let upstreams = detect_upstreams(&cfg, &probe_http).await;
        let model = selected_model(&cfg, &upstreams.primary().models());
        assert!(
            !model.trim().is_empty(),
            "set UPSTREAM_DEFAULT_MODEL, or expose at least one model from the upstream"
        );

        // Real tool smoke needs the time schema to be offered.
        cfg.time_enabled = std::env::var("REAL_UPSTREAM_TEST_TOOLS")
            .ok()
            .is_some_and(|v| matches!(v.as_str(), "1" | "true" | "yes" | "on"));

        let capabilities = Arc::new(probe_capabilities(&cfg, &probe_http, &upstreams, true).await);
        let cfg = Arc::new(cfg);
        let http = phantasm_orchestrator::build_http_client().expect("build http client");
        let state = build_state_with_upstreams(cfg, capabilities, http, upstreams);
        let base = spawn(routes::router(state)).await;

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(180))
            .build()
            .expect("build test client");

        Self {
            base,
            client,
            auth_token,
            model,
        }
    }

    fn get(&self, path: &str) -> RequestBuilder {
        authed(
            self.client.get(format!("{}{}", self.base, path)),
            &self.auth_token,
        )
    }

    fn post(&self, path: &str) -> RequestBuilder {
        authed(
            self.client.post(format!("{}{}", self.base, path)),
            &self.auth_token,
        )
    }
}

fn truthy_env(key: &str) -> bool {
    std::env::var(key)
        .ok()
        .is_some_and(|v| matches!(v.as_str(), "1" | "true" | "yes" | "on"))
}

fn upstream_kind_env() -> String {
    std::env::var("UPSTREAM_KIND")
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn sse_events(body: &str) -> (Vec<Value>, bool) {
    let mut events = Vec::new();
    let mut saw_done = false;
    for line in body.lines() {
        let Some(data) = line.strip_prefix("data: ") else {
            continue;
        };
        if data == "[DONE]" {
            saw_done = true;
            continue;
        }
        events.push(serde_json::from_str(data).expect("SSE JSON event"));
    }
    (events, saw_done)
}

fn reasoning_text(events: &[Value]) -> String {
    events
        .iter()
        .filter_map(|event| event["choices"][0]["delta"]["reasoning_content"].as_str())
        .collect()
}

fn content_text(events: &[Value]) -> String {
    events
        .iter()
        .filter_map(|event| event["choices"][0]["delta"]["content"].as_str())
        .collect()
}

async fn real_harness() -> RealHarness {
    let cfg = Config::from_env().expect("load test config from environment");
    RealHarness::start(cfg).await
}

#[tokio::test]
#[ignore = "requires a real upstream model host; see docs/REAL_UPSTREAM_TESTS.md"]
async fn real_upstream_plain_chat_smoke() {
    let h = real_harness().await;

    let models_resp = h.get("/v1/models").send().await.expect("GET /v1/models");
    assert!(
        models_resp.status().is_success(),
        "GET /v1/models failed: {}",
        models_resp.status()
    );
    let models: Value = models_resp.json().await.expect("models JSON");
    assert!(
        models["data"]
            .as_array()
            .is_some_and(|data| !data.is_empty()),
        "expected /v1/models to advertise at least one model, got {models}"
    );

    let capabilities_resp = h
        .get("/v1/capabilities")
        .send()
        .await
        .expect("GET /v1/capabilities");
    assert!(
        capabilities_resp.status().is_success(),
        "GET /v1/capabilities failed: {}",
        capabilities_resp.status()
    );
    let capabilities: Value = capabilities_resp.json().await.expect("capabilities JSON");
    assert!(
        capabilities["version"]
            .as_str()
            .is_some_and(|version| !version.trim().is_empty()),
        "expected /v1/capabilities version, got {capabilities}"
    );
    assert!(
        capabilities["models"]
            .as_array()
            .is_some_and(|data| !data.is_empty()),
        "expected /v1/capabilities to advertise at least one model, got {capabilities}"
    );

    let non_stream = h
        .post("/v1/chat/completions")
        .json(&serde_json::json!({
            "model": h.model,
            "stream": false,
            "messages": [{"role": "user", "content": "Reply with one short sentence."}]
        }))
        .send()
        .await
        .expect("POST /v1/chat/completions non-streaming");
    assert!(
        non_stream.status().is_success(),
        "non-streaming chat failed: {} {}",
        non_stream.status(),
        non_stream.text().await.unwrap_or_default()
    );
    let completion: Value = non_stream.json().await.expect("completion JSON");
    let content = completion["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or_default()
        .trim();
    assert!(
        !content.is_empty(),
        "expected non-streaming completion content, got {completion}"
    );

    let stream = h
        .post("/v1/chat/completions")
        .json(&serde_json::json!({
            "model": h.model,
            "stream": true,
            "messages": [{"role": "user", "content": "Reply with one short sentence."}]
        }))
        .send()
        .await
        .expect("POST /v1/chat/completions streaming");
    assert!(
        stream.status().is_success(),
        "streaming chat failed: {} {}",
        stream.status(),
        stream.text().await.unwrap_or_default()
    );
    let body = stream.text().await.expect("stream body");
    let (events, saw_done) = sse_events(&body);
    let mut content = String::new();
    for event in events {
        if let Some(delta) = event["choices"][0]["delta"]["content"].as_str() {
            content.push_str(delta);
        }
    }
    assert!(saw_done, "expected OpenAI [DONE] sentinel, got {body}");
    assert!(
        !content.trim().is_empty(),
        "expected streaming content delta, got {body}"
    );
}

#[tokio::test]
#[ignore = "requires a real vLLM server; run with just vllm-test"]
async fn real_upstream_vllm_server_usage_mode() {
    if upstream_kind_env() != "vllm" {
        eprintln!("skipping: forced continuous usage is a vLLM-specific mode");
        return;
    }

    let h = real_harness().await;
    let expect_continuous = truthy_env("REAL_VLLM_EXPECT_CONTINUOUS_USAGE");

    // Verify which server mode the just recipe actually launched. The request
    // asks only for the standard final usage trailer; non-null usage on choice
    // chunks must therefore come from vLLM's server-wide force flag.
    let upstream_base = std::env::var("UPSTREAM_BASE_URL")
        .expect("UPSTREAM_BASE_URL is set by the real-upstream recipe");
    let upstream_chat = if upstream_base.trim_end_matches('/').ends_with("/v1") {
        format!("{}/chat/completions", upstream_base.trim_end_matches('/'))
    } else {
        format!(
            "{}/v1/chat/completions",
            upstream_base.trim_end_matches('/')
        )
    };
    let upstream_token = std::env::var("UPSTREAM_API_KEY")
        .ok()
        .filter(|token| !token.trim().is_empty());
    let upstream_response = authed(h.client.post(upstream_chat), &upstream_token)
        .json(&serde_json::json!({
            "model": h.model,
            "stream": true,
            "stream_options": { "include_usage": true },
            "chat_template_kwargs": { "enable_thinking": false },
            "messages": [{
                "role": "user",
                "content": "Reply with one short sentence."
            }]
        }))
        .send()
        .await
        .expect("direct vLLM streaming request");
    let upstream_status = upstream_response.status();
    let upstream_body = upstream_response.text().await.expect("vLLM stream body");
    assert!(
        upstream_status.is_success(),
        "direct vLLM stream returned {upstream_status}: {upstream_body}"
    );
    let (upstream_events, upstream_done) = sse_events(&upstream_body);
    assert!(upstream_done, "direct vLLM stream omitted [DONE]");
    let choice_events: Vec<&Value> = upstream_events
        .iter()
        .filter(|event| {
            event["choices"]
                .as_array()
                .is_some_and(|choices| !choices.is_empty())
        })
        .collect();
    assert!(
        !choice_events.is_empty(),
        "direct vLLM stream emitted no choice chunks: {upstream_body}"
    );
    let choice_usage_count = choice_events
        .iter()
        .filter(|event| !event["usage"].is_null())
        .count();
    if expect_continuous {
        assert!(
            choice_usage_count > 0,
            "expected --enable-force-include-usage to put usage on choice chunks: {upstream_body}"
        );
    } else {
        assert_eq!(
            choice_usage_count, 0,
            "expected final-only usage without the force flag: {upstream_body}"
        );
    }

    // The client-facing request does not send `continuous_usage_stats`. In the
    // forced phase this reproduces Maple's unsolicited cumulative usage shape;
    // Phantasm must still relay the content instead of consuming every chunk.
    let response = h
        .post("/v1/chat/completions")
        .json(&serde_json::json!({
            "model": h.model,
            "stream": true,
            "reasoning_effort": "none",
            "messages": [{
                "role": "user",
                "content": "Reply with one short sentence."
            }]
        }))
        .send()
        .await
        .expect("orchestrated vLLM streaming request");
    let status = response.status();
    let body = response.text().await.expect("orchestrated stream body");
    assert!(
        status.is_success(),
        "expect_continuous={expect_continuous} returned {status}: {body}"
    );

    let (events, saw_done) = sse_events(&body);
    assert!(
        saw_done,
        "expect_continuous={expect_continuous} omitted [DONE]: {body}"
    );
    let content = content_text(&events);
    assert!(
        !content.trim().is_empty(),
        "expect_continuous={expect_continuous} lost every content delta: {body}"
    );
}

#[tokio::test]
#[ignore = "requires a real upstream model host; see docs/REAL_UPSTREAM_TESTS.md"]
async fn real_upstream_bad_model_surfaces_upstream_error() {
    let kind = upstream_kind_env();
    if kind != "ollama"
        && kind != "native_ollama"
        && !truthy_env("REAL_UPSTREAM_EXPECT_BAD_MODEL_ERROR")
    {
        eprintln!(
            "skipping: {kind} may ignore unknown model ids; set REAL_UPSTREAM_EXPECT_BAD_MODEL_ERROR=1 to enforce"
        );
        return;
    }

    let h = real_harness().await;
    let bad_model = std::env::var("REAL_UPSTREAM_BAD_MODEL")
        .unwrap_or_else(|_| "__phantasm_missing_model__".into());

    let resp = h
        .post("/v1/chat/completions")
        .json(&serde_json::json!({
            "model": bad_model,
            "stream": false,
            "messages": [{"role": "user", "content": "hello"}]
        }))
        .send()
        .await
        .expect("POST /v1/chat/completions with bogus model");
    assert_eq!(
        resp.status().as_u16(),
        502,
        "bad model should surface as upstream_error"
    );
    let body: Value = resp.json().await.expect("error JSON");
    assert_eq!(body["error"]["type"], "upstream_error");
}

#[tokio::test]
#[ignore = "requires REAL_UPSTREAM_TEST_THINKING=1 and a thinking-capable model"]
async fn real_upstream_thinking_streams_reasoning() {
    if !truthy_env("REAL_UPSTREAM_TEST_THINKING") {
        eprintln!("skipping: set REAL_UPSTREAM_TEST_THINKING=1 to enable");
        return;
    }
    let h = real_harness().await;

    let thinking_on = h
        .post("/v1/chat/completions")
        .json(&serde_json::json!({
            "model": h.model,
            "stream": true,
            "reasoning_effort": "medium",
            "messages": [{
                "role": "user",
                "content": "Think briefly, then answer with exactly: done"
            }]
        }))
        .send()
        .await
        .expect("POST /v1/chat/completions thinking stream");
    assert!(
        thinking_on.status().is_success(),
        "thinking chat failed: {} {}",
        thinking_on.status(),
        thinking_on.text().await.unwrap_or_default()
    );
    let thinking_on_body = thinking_on.text().await.expect("stream body");
    let (thinking_on_events, saw_done) = sse_events(&thinking_on_body);
    assert!(
        saw_done,
        "expected OpenAI [DONE] sentinel, got {thinking_on_body}"
    );
    if thinking_on_body.contains("does not support thinking") {
        eprintln!("skipping: selected model does not support thinking");
        return;
    }
    let reasoning = reasoning_text(&thinking_on_events);
    assert!(
        !reasoning.trim().is_empty(),
        "expected reasoning_content deltas from thinking-capable upstream, got {thinking_on_body}"
    );
    let thinking_on_content = content_text(&thinking_on_events);
    assert!(
        !thinking_on_content.contains("<think>") && !thinking_on_content.contains("</think>"),
        "expected raw thinking tags to be normalized out of visible content, got {thinking_on_body}"
    );

    let thinking_off = h
        .post("/v1/chat/completions")
        .json(&serde_json::json!({
            "model": h.model,
            "stream": true,
            "reasoning_effort": "none",
            "messages": [{
                "role": "user",
                "content": "Answer with exactly: done"
            }]
        }))
        .send()
        .await
        .expect("POST /v1/chat/completions no-thinking stream");
    assert!(
        thinking_off.status().is_success(),
        "no-thinking chat failed: {} {}",
        thinking_off.status(),
        thinking_off.text().await.unwrap_or_default()
    );
    let thinking_off_body = thinking_off.text().await.expect("stream body");
    let (thinking_off_events, saw_done) = sse_events(&thinking_off_body);
    assert!(
        saw_done,
        "expected OpenAI [DONE] sentinel, got {thinking_off_body}"
    );
    assert!(
        reasoning_text(&thinking_off_events).trim().is_empty(),
        "expected reasoning_effort=none to suppress reasoning_content, got {thinking_off_body}"
    );
    let thinking_off_content = content_text(&thinking_off_events);
    assert!(
        !thinking_off_content.contains("<think>") && !thinking_off_content.contains("</think>"),
        "expected reasoning_effort=none to suppress raw thinking tags, got {thinking_off_body}"
    );
}

#[tokio::test]
#[ignore = "requires REAL_UPSTREAM_TEST_TOOLS=1 and a tool-capable model/template"]
async fn real_upstream_model_can_call_time_tool() {
    if !truthy_env("REAL_UPSTREAM_TEST_TOOLS") {
        eprintln!("skipping: set REAL_UPSTREAM_TEST_TOOLS=1 to enable");
        return;
    }
    let h = real_harness().await;
    let resp = h
        .post("/v1/chat/completions")
        .json(&serde_json::json!({
            "model": h.model,
            "stream": true,
            "tools": [{ "type": "function", "function": { "name": "time" } }],
            "tool_choice": "required",
            "messages": [{
                "role": "user",
                "content": "Use the time tool to get the current server Unix timestamp. Then answer with the timestamp from the tool result."
            }]
        }))
        .send()
        .await
        .expect("POST /v1/chat/completions tool call");
    assert!(
        resp.status().is_success(),
        "tool chat failed: {} {}",
        resp.status(),
        resp.text().await.unwrap_or_default()
    );
    let body = resp.text().await.expect("stream body");
    let (events, saw_done) = sse_events(&body);
    assert!(saw_done, "expected OpenAI [DONE] sentinel, got {body}");

    let status_text = events
        .iter()
        .filter_map(|event| event["x_status"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        status_text.contains("checking time"),
        "expected time tool execution status, got {body}"
    );
}
