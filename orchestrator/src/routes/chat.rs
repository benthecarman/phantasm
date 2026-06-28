//! `POST /v1/chat/completions` (FR-O2) — the single OpenAI-compatible chat
//! endpoint. Streaming requests get an SSE token stream; non-streaming requests
//! get a single `chat.completion` object.
//!
//! For streaming, errors that occur after the first byte cannot change the HTTP
//! status, so they are surfaced inside the stream. For non-streaming we collect
//! before responding and can therefore return a proper error status.

use std::convert::Infallible;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::Json;
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::error::AppError;
use crate::openai::sse::{done_event, ChunkFactory};
use crate::openai::types::{ChatMessage, ChatRequest, ToolCall};
use crate::orchestrator::{run_turn, TurnEvent};
use crate::state::{AppState, ContinuationCache};
use crate::turn_registry::ActiveTurn;

pub async fn chat_completions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<ChatRequest>,
) -> Response {
    if req.messages.is_empty() {
        return AppError::BadRequest("`messages` must not be empty".into()).into_response();
    }

    if let Err(e) = validate_image_limits(
        &req.messages,
        state.cfg.max_request_images,
        state.cfg.max_request_image_bytes,
    ) {
        return e.into_response();
    }

    // The downstream OpenAI response echoes back the model the client asked for
    // (including any mode suffix); the base model is what we run upstream and is
    // resolved inside `spawn_turn`.
    let model_name = req
        .model
        .clone()
        .unwrap_or_else(|| state.cfg.default_model.clone());
    let stream = req.stream;

    // Resumable streaming turns (FR-O8 reworked): a turn started with an
    // `Idempotency-Key` keeps running across client disconnects and is buffered
    // server-side, so backgrounding the app no longer loses a long generation —
    // a reconnect with the same key replays it. Non-streaming requests and
    // standard clients (no key) take the connection-bound legacy path below.
    if let (Some(key), true) = (header_str(&headers, "idempotency-key"), stream) {
        let last_event_id =
            header_str(&headers, "last-event-id").and_then(|s| s.parse::<usize>().ok());
        // When images are delivered inline (a store exists but mints no absolute
        // URLs), spill their base64 to the store so the buffered log holds a
        // compact ref, not megabytes — re-inlined per stream so delivery is
        // unchanged. With a public base, delivery is already URL-based (no spill);
        // with no store, there's nowhere to spill (base64 stays, bounded by cap).
        let spill = state.images.clone().filter(|s| !s.has_public_base());
        let (active, is_new) = state.turns.get_or_create(&key);
        if is_new {
            let rx = spawn_turn(&state, req, active.cancel.clone()).await;
            spawn_pump(
                rx,
                active.clone(),
                state.continuations.clone(),
                spill.clone(),
            );
        }
        // Replay from the client's cursor (or the start); the iOS app rebuilds
        // from scratch and so omits `Last-Event-ID`.
        let start = last_event_id.map(|n| n + 1).unwrap_or(0);
        return attach_response(model_name, active, start, spill);
    }

    // Legacy / standard-client path: the turn is bound to this connection and
    // cancelled on disconnect via the SSE drop-guard (see `stream_response`).
    let cancel = CancellationToken::new();
    let rx = spawn_turn(&state, req, cancel.clone()).await;
    if stream {
        stream_response(model_name, rx, cancel, state.continuations.clone())
    } else {
        collect_response(model_name, rx, state.continuations.clone()).await
    }
}

/// Tracks an attached SSE responder on an `ActiveTurn` for its lifetime, so the
/// watchdog can tell a backgrounded-but-watched turn from an abandoned one.
struct AttachGuard {
    turn: Arc<ActiveTurn>,
}

impl AttachGuard {
    fn new(turn: Arc<ActiveTurn>) -> Self {
        turn.attach();
        Self { turn }
    }
}

impl Drop for AttachGuard {
    fn drop(&mut self) {
        self.turn.detach();
    }
}

#[derive(Debug, Deserialize)]
pub struct CancelRequest {
    /// The turn's `Idempotency-Key` (the app's pending-assistant message id).
    pub turn_id: String,
}

/// `POST /v1/chat/cancel` — explicitly cancel a resumable turn by its
/// `Idempotency-Key`. Fires the turn's cancellation token (which interrupts any
/// in-flight tool work, including a running ComfyUI generation) and drops it from
/// the registry. This is the new app's Stop button: a resumable turn no longer
/// cancels on disconnect, so Stop signals it here to free the GPU immediately.
/// An unknown id is a no-op — a turn that already finished, was never resumable,
/// or was started by a legacy client (which cancels by disconnecting). Always
/// `204` so the app's Stop is fire-and-forget.
pub async fn cancel(State(state): State<AppState>, Json(req): Json<CancelRequest>) -> Response {
    if let Some(turn) = state.turns.remove(&req.turn_id) {
        turn.cancel.cancel();
    }
    StatusCode::NO_CONTENT.into_response()
}

/// Read a non-empty, trimmed request header value as a `String`.
fn header_str(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Prepare the messages (incl. intra-turn continuation splicing) and spawn the
/// turn task, returning the channel its `TurnEvent`s arrive on. The turn owns
/// clones of everything it needs and runs detached on the provided `cancel`.
async fn spawn_turn(
    state: &AppState,
    req: ChatRequest,
    cancel: CancellationToken,
) -> mpsc::Receiver<TurnEvent> {
    use crate::orchestrator::tools::{ToolExecutor, ToolRegistry};

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
    let model = base_model;

    let (tx, rx) = mpsc::channel::<TurnEvent>(64);

    let cfg = state.cfg.clone();
    let backend = state.upstream.clone();
    let tools = ToolRegistry::new(
        state.cfg.clone(),
        state.http.clone(),
        state.code_exec.clone(),
    );
    let sem = state.upstream_sem.clone();
    let images = state.images.clone();

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
            images,
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

    rx
}

/// Drain a turn's events into its `ActiveTurn` log so they survive client
/// disconnects (the resumable path). Co-occurring server tool results carried on
/// a `ToolCalls` event are stashed into the continuation cache here — once, on
/// the producing side — then stripped so the buffered log stays small and a
/// replay never re-stashes. When `spill` is set, inline base64 images are
/// offloaded to the blob store so the log holds a compact ref instead of
/// megabytes (re-inlined by `attach_response`). When the turn's channel closes
/// without an explicit terminal (e.g. a future cancellation), `finish()` releases
/// any waiters.
fn spawn_pump(
    mut rx: mpsc::Receiver<TurnEvent>,
    active: Arc<ActiveTurn>,
    continuations: ContinuationCache,
    spill: Option<crate::images::BlobStore>,
) {
    use crate::tools::image_delivery::offload_inline_images;
    tokio::spawn(async move {
        while let Some(ev) = rx.recv().await {
            let ev = match ev {
                TurnEvent::ToolCalls { app, held } => {
                    if let Some(held) = held {
                        if let Some(key) = app.first().and_then(|c| c.id.clone()) {
                            continuations.stash(key, held).await;
                        }
                    }
                    TurnEvent::ToolCalls { app, held: None }
                }
                // A generated image rides the answer as a base64 data-URI token;
                // offload it so the buffer holds a ref, not the bytes.
                TurnEvent::Token(t) if spill.is_some() && t.contains("](data:") => {
                    let store = spill.as_ref().unwrap();
                    TurnEvent::Token(offload_inline_images(&t, store).await)
                }
                other => other,
            };
            active.push(ev);
        }
        active.finish();
    });
}

/// Build the SSE response by attaching to a buffered turn: replay the log from
/// `start`, then tail live events until the turn ends. Each event is stamped
/// with its log index as the SSE `id:`, so a reconnecting client can resume via
/// `Last-Event-ID`. Crucially there is **no** drop-guard here — dropping this
/// stream (the client disconnecting) detaches the responder but leaves the turn
/// running, which is what lets a backgrounded generation finish.
fn attach_response(
    model: String,
    active: Arc<ActiveTurn>,
    start: usize,
    spill: Option<crate::images::BlobStore>,
) -> Response {
    use crate::tools::image_delivery::inline_image_refs;
    let factory = ChunkFactory::new(model);
    let mut len_rx = active.subscribe();
    let body = async_stream::stream! {
        // Count this responder as attached for as long as the stream lives, so the
        // abandoned-turn watchdog only reclaims turns with no listener. Dropping
        // the stream (client disconnect) drops the guard, restarting that clock.
        let _attach = AttachGuard::new(active.clone());
        yield factory.role_open();
        let mut idx = start;
        loop {
            let (events, done) = active.snapshot_from(idx);
            for ev in events {
                let id = idx.to_string();
                idx += 1;
                match ev {
                    TurnEvent::Status(s) => yield factory.status(&s).id(id),
                    TurnEvent::Progress { status, progress } => {
                        yield factory.progress(&status, progress).id(id)
                    }
                    TurnEvent::Reasoning(r) => yield factory.reasoning(&r).id(id),
                    // Re-inline any image the pump spilled to the store, so the
                    // client receives the same base64 it would have un-spilled.
                    TurnEvent::Token(t) => {
                        let t = match spill.as_ref() {
                            Some(store) if t.contains("/v1/files/") => {
                                inline_image_refs(&t, store).await
                            }
                            _ => t,
                        };
                        yield factory.token(&t).id(id)
                    }
                    TurnEvent::ToolCalls { app, .. } => yield factory.tool_calls(&app).id(id),
                    TurnEvent::Error(e) => {
                        yield factory.status(&format!("error: {e}")).id(id);
                        yield factory.token(&format!("\n\n⚠️ {e}"));
                        yield factory.finish("stop");
                        yield done_event();
                        return;
                    }
                    TurnEvent::Done { reason } => {
                        yield factory.finish(&reason).id(id);
                        yield done_event();
                        return;
                    }
                }
            }
            if done {
                // Terminal without an explicit Done/Error event (e.g. a turn
                // cancelled mid-flight): just end the stream, matching the legacy
                // channel-closed-without-Done behavior.
                break;
            }
            // Wait for the next append; an error means the turn task is gone.
            if len_rx.changed().await.is_err() {
                break;
            }
        }
    };

    Sse::new(body.map(Ok::<Event, Infallible>))
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
        .into_response()
}

/// Reject a request carrying too many or too-large inline images before we spend
/// the turn's memory on it. The body-size limit (`DefaultBodyLimit`) is the coarse
/// guard; this is the finer one — many small images, or a single oversized image
/// that still fits under the body cap. Counts both attached `image_url` parts and
/// `data:` URIs embedded in message text (the form generated images take in
/// re-sent history). Reference URLs (no `;base64,`) measure short and pass the
/// size check, so this stays correct once images move to server-hosted URLs.
fn validate_image_limits(
    messages: &[ChatMessage],
    max_images: usize,
    max_bytes_each: usize,
) -> Result<(), AppError> {
    let mut count = 0usize;
    for m in messages {
        let Some(content) = m.content.as_ref() else {
            continue;
        };
        for payload in content.image_payloads() {
            count += 1;
            if count > max_images {
                return Err(AppError::PayloadTooLarge(format!(
                    "too many images in request (max {max_images})"
                )));
            }
            // base64 decodes to ~3/4 its length; estimate rather than decode the
            // (potentially multi-MB) payload just to measure it.
            let approx_bytes = payload.len() / 4 * 3;
            if approx_bytes > max_bytes_each {
                return Err(AppError::PayloadTooLarge(format!(
                    "an image exceeds the per-image cap of {max_bytes_each} bytes"
                )));
            }
        }
    }
    Ok(())
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
                TurnEvent::Progress { status, progress } => yield factory.progress(&status, progress),
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
            TurnEvent::Status(_) | TurnEvent::Progress { .. } | TurnEvent::Reasoning(_) => {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::openai::types::{ContentPart, ImageUrl, MessageContent};

    fn data_uri(payload_len: usize) -> String {
        format!("data:image/png;base64,{}", "A".repeat(payload_len))
    }

    fn user_text(text: &str) -> ChatMessage {
        ChatMessage {
            role: "user".into(),
            content: Some(MessageContent::Text(text.into())),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    fn user_attached(payload_len: usize) -> ChatMessage {
        ChatMessage {
            role: "user".into(),
            content: Some(MessageContent::Parts(vec![ContentPart::ImageUrl {
                image_url: ImageUrl {
                    url: data_uri(payload_len),
                },
            }])),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    #[test]
    fn within_limits_passes() {
        let messages = vec![
            user_attached(40),
            user_text(&format!("![generated]({})", data_uri(40))),
        ];
        assert!(validate_image_limits(&messages, 16, 16 * 1024 * 1024).is_ok());
    }

    #[test]
    fn too_many_images_rejected() {
        // Three images (one attached + two embedded in text) against a cap of 2.
        let messages = vec![
            user_attached(8),
            user_text(&format!("![a]({}) ![b]({})", data_uri(8), data_uri(8))),
        ];
        let err = validate_image_limits(&messages, 2, 16 * 1024 * 1024).unwrap_err();
        assert!(matches!(err, AppError::PayloadTooLarge(_)));
    }

    #[test]
    fn oversized_single_image_rejected() {
        // 400 base64 chars ≈ 300 decoded bytes, over a 100-byte cap.
        let messages = vec![user_attached(400)];
        let err = validate_image_limits(&messages, 16, 100).unwrap_err();
        assert!(matches!(err, AppError::PayloadTooLarge(_)));
    }

    #[test]
    fn reference_url_passes_size_check() {
        // A server-hosted image reference (`image_url` with an http URL, no
        // `;base64,`) is counted as an image but measures short, so it must not
        // trip even a tiny per-image byte cap — keeping the guard correct once
        // images move to URL references.
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: Some(MessageContent::Parts(vec![ContentPart::ImageUrl {
                image_url: ImageUrl {
                    url: "https://host/images/abc123.png".into(),
                },
            }])),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }];
        assert!(validate_image_limits(&messages, 16, 100).is_ok());
    }
}
