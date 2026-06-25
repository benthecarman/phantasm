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
use serde_json::json;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::error::AppError;
use crate::openai::sse::{done_event, ChunkFactory};
use crate::openai::types::ChatRequest;
use crate::orchestrator::{run_turn, TurnEvent};
use crate::state::AppState;

pub async fn chat_completions(
    State(state): State<AppState>,
    Json(req): Json<ChatRequest>,
) -> Response {
    if req.messages.is_empty() {
        return AppError::BadRequest("`messages` must not be empty".into()).into_response();
    }

    // Per XR-2 the app resends full history each turn, including multi-MB base64
    // image data-URIs from prior turns — so move the heavy fields out of `req`
    // rather than cloning them.
    let ChatRequest {
        model,
        stream,
        messages,
        enabled_tools,
        research,
        extra: options,
        ..
    } = req;
    let model_name = model.unwrap_or_else(|| state.cfg.default_model.clone());
    let model = model_name.clone();

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
        if cfg.log_content {
            tracing::debug!(turn_id, messages = ?messages, "turn content");
        }

        tokio::spawn(async move {
            let started = std::time::Instant::now();
            tracing::info!(turn_id, model = %log_model, stream, tools_offered, research, "turn started");
            run_turn(
                cfg,
                backend,
                tools,
                sem,
                messages,
                model,
                options,
                enabled_tools,
                research,
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
        stream_response(model_name, rx, cancel)
    } else {
        collect_response(model_name, rx).await
    }
}

fn stream_response(
    model: String,
    mut rx: mpsc::Receiver<TurnEvent>,
    cancel: CancellationToken,
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
                TurnEvent::Token(t) => yield factory.token(&t),
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

async fn collect_response(model: String, mut rx: mpsc::Receiver<TurnEvent>) -> Response {
    let mut content = String::new();
    let mut reason = "stop".to_string();

    while let Some(ev) = rx.recv().await {
        match ev {
            TurnEvent::Token(t) => content.push_str(&t),
            TurnEvent::Done { reason: r } => {
                reason = r;
                break;
            }
            TurnEvent::Error(e) => {
                // Collected before responding, so we can use a real status.
                return AppError::OllamaError(e).into_response();
            }
            TurnEvent::Status(_) => {}
        }
    }

    let body = json!({
        "id": format!("chatcmpl-{}", uuid::Uuid::new_v4().simple()),
        "object": "chat.completion",
        "created": now_secs(),
        "model": model,
        "choices": [{
            "index": 0,
            "message": { "role": "assistant", "content": content },
            "finish_reason": reason,
        }],
    });
    Json(body).into_response()
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
