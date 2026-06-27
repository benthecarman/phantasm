//! `POST /v1/chat/completions` (FR-O2) — the single OpenAI-compatible chat
//! endpoint. Streaming requests get an SSE token stream; non-streaming requests
//! get a single `chat.completion` object.
//!
//! For streaming, errors that occur after the first byte cannot change the HTTP
//! status, so they are surfaced inside the stream. For non-streaming we collect
//! before responding and can therefore return a proper error status.

use std::convert::Infallible;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::State;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::Json;
use futures_util::StreamExt;
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::error::AppError;
use crate::openai::sse::{done_event, ChunkFactory};
use crate::openai::types::{ChatMessage, ChatRequest, ToolCall};
use crate::orchestrator::{run_turn, TurnEvent};
use crate::state::{AppState, ContinuationCache};

pub async fn chat_completions(
    State(state): State<AppState>,
    Json(req): Json<ChatRequest>,
) -> Response {
    if req.messages.is_empty() {
        return AppError::BadRequest("`messages` must not be empty".into()).into_response();
    }

    // Resolve the per-turn tool selection and any app-hosted tool definitions
    // from the standard `tools`/`tool_choice` fields before we move the rest of
    // the request apart.
    let enabled_tools = req.tool_selection();
    let app_tools = req.app_tools();

    // Per XR-2 the app resends full history each turn, including multi-MB base64
    // image data-URIs from prior turns — so move the heavy fields out of `req`
    // rather than cloning them.
    let ChatRequest {
        model,
        stream,
        mut messages,
        extra: options,
        ..
    } = req;

    // Intra-turn continuation (see `ContinuationCache`): if this request answers
    // a batch we paused because server calls co-occurred with the app call,
    // resume from the stashed history so that server work isn't lost. The app's
    // answers are the trailing `tool`-role results; we splice them onto the held
    // history (which already carries the assistant message + server results) in
    // place of the app's own — shorter — re-sent tail.
    let tail_start = trailing_tool_results_start(&messages);
    let tail_ids: Vec<String> = messages[tail_start..]
        .iter()
        .filter_map(|m| m.tool_call_id.clone())
        .collect();
    if !tail_ids.is_empty() {
        if let Some(mut held) = state.continuations.take(&tail_ids).await {
            held.extend(messages.split_off(tail_start));
            messages = held;
        }
    }
    let requested_model = model.unwrap_or_else(|| state.cfg.default_model.clone());
    // Deep Research is selected by the model id, not a request flag: split the
    // requested model into its base model and an optional research preset.
    let (base_model, preset) = state.cfg.presets().resolve_model(&requested_model);
    // The downstream OpenAI response echoes back the model the client asked for
    // (including any mode suffix); the base model is what we run upstream.
    let model_name = requested_model;
    let model = base_model;

    let cancel = CancellationToken::new();
    let (tx, rx) = mpsc::channel::<TurnEvent>(64);

    // Spawn the turn; it owns clones of everything it needs.
    {
        use crate::orchestrator::tools::{ToolExecutor, ToolRegistry};
        let cfg = state.cfg.clone();
        let backend = state.upstream.clone();
        let tools = ToolRegistry::new(state.cfg.clone(), state.http.clone());
        let sem = state.upstream_sem.clone();
        let cancel = cancel.clone();

        // Per-turn structured logging (NFR-O7). Message content is never logged
        // unless explicitly enabled.
        let turn_id = uuid::Uuid::new_v4().simple().to_string();
        // Count what's actually offered after the client's per-request selection,
        // so the log reflects the real tool surface for this turn.
        let tools_offered =
            crate::orchestrator::turn::select_schemas(tools.schemas(), &enabled_tools).len();
        let log_model = model.clone();
        // Resolved research mode id (if any) for per-turn logging.
        let mode = preset.map(|p| p.id);
        if cfg.log_content {
            tracing::debug!(turn_id, messages = ?messages, "turn content");
        }

        tokio::spawn(async move {
            let started = std::time::Instant::now();
            tracing::info!(turn_id, model = %log_model, stream, tools_offered, mode, "turn started");
            run_turn(
                cfg,
                backend,
                tools,
                sem,
                messages,
                model,
                options,
                enabled_tools,
                app_tools,
                preset,
                tx,
                cancel,
            )
            .await;
            tracing::info!(
                turn_id,
                model = %log_model,
                elapsed_ms = started.elapsed().as_millis() as u64,
                "turn finished"
            );
        });
    }

    if stream {
        stream_response(model_name, rx, cancel, state.continuations.clone())
    } else {
        collect_response(model_name, rx, state.continuations.clone()).await
    }
}

/// Index of the trailing run of `tool`-role messages — the answers to the most
/// recent forwarded tool-call batch. Everything from here to the end is the
/// continuation tail; `messages.len()` when the last message isn't a tool result.
fn trailing_tool_results_start(messages: &[ChatMessage]) -> usize {
    messages
        .iter()
        .rposition(|m| m.role != "tool")
        .map(|i| i + 1)
        .unwrap_or(0)
}

fn stream_response(
    model: String,
    mut rx: mpsc::Receiver<TurnEvent>,
    cancel: CancellationToken,
    continuations: ContinuationCache,
) -> Response {
    let factory = ChunkFactory::new(model);
    // When the client disconnects, axum drops this stream, dropping the guard,
    // which cancels the turn and any in-flight tool work (FR-O8).
    let guard = cancel.drop_guard();

    let body = async_stream::stream! {
        let _guard = guard;
        yield factory.role_open();
        while let Some(ev) = rx.recv().await {
            match ev {
                TurnEvent::Status(s) => yield factory.status(&s),
                TurnEvent::Reasoning(r) => yield factory.reasoning(&r),
                TurnEvent::Token(t) => yield factory.token(&t),
                TurnEvent::ToolCalls { app, held } => {
                    // Stash the paused turn (server results + assistant message)
                    // keyed by the forwarded app call the app echoes back next
                    // request, then hand the app its calls. `held` is None when no
                    // server calls co-occurred — nothing to resume.
                    if let Some(held) = held {
                        if let Some(key) = app.first().and_then(|c| c.id.clone()) {
                            continuations.stash(key, held).await;
                        }
                    }
                    yield factory.tool_calls(&app);
                }
                TurnEvent::Error(e) => {
                    yield factory.status(&format!("error: {e}"));
                    yield factory.token(&format!("\n\n⚠️ {e}"));
                    yield factory.finish("stop");
                    yield done_event();
                    return;
                }
                TurnEvent::Done { reason } => {
                    yield factory.finish(&reason);
                    yield done_event();
                    return;
                }
            }
        }
        // Channel closed without an explicit Done (e.g. cancelled) — just end.
    };

    Sse::new(body.map(Ok::<Event, Infallible>))
        .keep_alive(KeepAlive::new().interval(std::time::Duration::from_secs(15)))
        .into_response()
}

async fn collect_response(
    model: String,
    mut rx: mpsc::Receiver<TurnEvent>,
    continuations: ContinuationCache,
) -> Response {
    let mut content = String::new();
    let mut reason = "stop".to_string();
    let mut tool_calls: Vec<ToolCall> = Vec::new();

    while let Some(ev) = rx.recv().await {
        match ev {
            TurnEvent::Token(t) => content.push_str(&t),
            TurnEvent::ToolCalls { app, held } => {
                if let Some(held) = held {
                    if let Some(key) = app.first().and_then(|c| c.id.clone()) {
                        continuations.stash(key, held).await;
                    }
                }
                tool_calls = app;
            }
            TurnEvent::Done { reason: r } => {
                reason = r;
                break;
            }
            TurnEvent::Error(e) => {
                // Collected before responding, so we can use a real status.
                return AppError::OllamaError(e).into_response();
            }
            TurnEvent::Status(_) | TurnEvent::Reasoning(_) => {
                // Non-streaming OpenAI completions expose only final content.
            }
        }
    }

    // App-hosted tool calls => standard `tool_calls` message with null content.
    let message = if tool_calls.is_empty() {
        json!({ "role": "assistant", "content": content })
    } else {
        json!({ "role": "assistant", "content": Value::Null, "tool_calls": wire_tool_calls(&tool_calls) })
    };

    let body = json!({
        "id": format!("chatcmpl-{}", uuid::Uuid::new_v4().simple()),
        "object": "chat.completion",
        "created": now_secs(),
        "model": model,
        "choices": [{
            "index": 0,
            "message": message,
            "finish_reason": reason,
        }],
    });
    Json(body).into_response()
}

/// Render forwarded tool calls as the non-streaming OpenAI `tool_calls` array
/// (`arguments` as a JSON string), sharing id-minting with the streaming path.
fn wire_tool_calls(calls: &[ToolCall]) -> Value {
    Value::Array(
        calls
            .iter()
            .map(|c| {
                json!({
                    "id": crate::openai::sse::ensure_call_id(c),
                    "type": "function",
                    "function": {
                        "name": c.function.name,
                        "arguments": c.function.arguments.to_json_string(),
                    }
                })
            })
            .collect(),
    )
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
