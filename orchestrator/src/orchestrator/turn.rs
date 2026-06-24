//! The heart of the orchestrator: the server-side tool loop (FR-O3).
//!
//! Two-phase model:
//!   * **Tool resolution** — non-streaming `chat_once` calls. While the model
//!     keeps requesting tools we execute them and feed results back, capped at
//!     `max_tool_iters`.
//!   * **Final answer** — once the model stops calling tools we re-issue the
//!     resolved messages as a *streaming* call and relay tokens to the app.
//!
//! Plain turns (no tools configured) skip straight to the streaming phase, which
//! is the low-overhead passthrough path (NFR-O3).
//!
//! All output is `TurnEvent`s on `tx`; errors after the first emission become
//! `TurnEvent::Error` rather than aborting, since the HTTP status is committed.
//! Cancellation is checked at every await via `cancel`.

use std::sync::Arc;

use futures_util::StreamExt;
use serde_json::{Map, Value};
use tokio::sync::{mpsc, Semaphore};
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::ollama::ChatBackend;
use crate::openai::types::ChatMessage;
use crate::orchestrator::tools::ToolExecutor;
use crate::orchestrator::TurnEvent;

#[allow(clippy::too_many_arguments)]
pub async fn run_turn<B, T>(
    cfg: Arc<Config>,
    backend: B,
    tools: T,
    sem: Arc<Semaphore>,
    mut messages: Vec<ChatMessage>,
    model: String,
    options: Map<String, Value>,
    tx: mpsc::Sender<TurnEvent>,
    cancel: CancellationToken,
) where
    B: ChatBackend,
    T: ToolExecutor,
{
    // Bound concurrent Ollama work; surface a wait if we have to queue (NFR-O2).
    let _permit = match sem.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => {
            let _ = tx
                .send(TurnEvent::Status("waiting for a free model slot…".into()))
                .await;
            tokio::select! {
                p = sem.acquire_owned() => match p {
                    Ok(p) => p,
                    Err(_) => {
                        let _ = tx.send(TurnEvent::Error("server shutting down".into())).await;
                        return;
                    }
                },
                _ = cancel.cancelled() => return,
            }
        }
    };

    if cancel.is_cancelled() {
        return;
    }

    let schemas = tools.schemas();

    // Plain fast path: no tools to offer => one streaming call.
    if schemas.is_empty() {
        stream_final(
            &backend,
            &model,
            &messages,
            &options,
            Vec::new(),
            &tx,
            &cancel,
        )
        .await;
        return;
    }

    let mut appends: Vec<String> = Vec::new();

    for _ in 0..cfg.max_tool_iters {
        if cancel.is_cancelled() {
            return;
        }

        let resp = tokio::select! {
            r = backend.chat_once(&model, &messages, &schemas, &options) => r,
            _ = cancel.cancelled() => return,
        };

        let resp = match resp {
            Ok(m) => m,
            Err(e) => {
                let _ = tx.send(TurnEvent::Error(e.to_string())).await;
                return;
            }
        };

        match resp.tool_calls.clone().filter(|c| !c.is_empty()) {
            None => {
                // Model produced a final answer — re-issue as a stream for live tokens.
                stream_final(&backend, &model, &messages, &options, appends, &tx, &cancel).await;
                return;
            }
            Some(calls) => {
                messages.push(resp); // assistant message carrying the tool_calls
                for call in &calls {
                    if cancel.is_cancelled() {
                        return;
                    }
                    let outcome = tools.execute(call, tx.clone(), cancel.clone()).await;
                    messages.push(outcome.message);
                    if let Some(extra) = outcome.append_to_answer {
                        appends.push(extra);
                    }
                }
            }
        }
    }

    // Iteration cap reached — stream whatever the model gives now (no tools).
    let _ = tx.send(TurnEvent::Status("finishing up…".into())).await;
    stream_final(&backend, &model, &messages, &options, appends, &tx, &cancel).await;
}

/// Issue a streaming call (without tools) and relay tokens, then append any
/// deferred content (e.g. generated images) and finish.
async fn stream_final<B: ChatBackend>(
    backend: &B,
    model: &str,
    messages: &[ChatMessage],
    options: &Map<String, Value>,
    appends: Vec<String>,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) {
    if cancel.is_cancelled() {
        return;
    }
    let stream = tokio::select! {
        s = backend.chat_stream(model, messages, options) => s,
        _ = cancel.cancelled() => return,
    };

    let mut stream = match stream {
        Ok(s) => s,
        Err(e) => {
            let _ = tx.send(TurnEvent::Error(e.to_string())).await;
            return;
        }
    };

    let mut reason = "stop".to_string();
    loop {
        let next = tokio::select! {
            n = stream.next() => n,
            _ = cancel.cancelled() => return,
        };
        match next {
            Some(Ok(delta)) => {
                if !delta.content.is_empty()
                    && tx.send(TurnEvent::Token(delta.content)).await.is_err()
                {
                    return; // client gone
                }
                if delta.done {
                    if let Some(r) = delta.done_reason {
                        reason = r;
                    }
                    break;
                }
            }
            Some(Err(e)) => {
                let _ = tx.send(TurnEvent::Error(e.to_string())).await;
                return;
            }
            None => break,
        }
    }

    for extra in appends {
        if tx
            .send(TurnEvent::Token(format!("\n\n{extra}")))
            .await
            .is_err()
        {
            return;
        }
    }

    let _ = tx.send(TurnEvent::Done { reason }).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ollama::{DeltaStream, StreamDelta};
    use crate::openai::types::{FunctionCall, RawArguments, ToolCall};
    use crate::orchestrator::tools::ToolOutcome;
    use std::sync::Mutex;

    // ---- scripted backend ----

    #[derive(Clone)]
    struct ScriptedBackend {
        // Each chat_once call pops the next scripted assistant message.
        once: Arc<Mutex<Vec<ChatMessage>>>,
        once_calls: Arc<Mutex<usize>>,
        final_tokens: Arc<Vec<String>>,
    }

    fn assistant(content: &str) -> ChatMessage {
        ChatMessage {
            role: "assistant".into(),
            content: Some(content.into()),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    fn assistant_calling(tool: &str) -> ChatMessage {
        ChatMessage {
            role: "assistant".into(),
            content: None,
            tool_calls: Some(vec![ToolCall {
                id: Some("call_1".into()),
                kind: "function".into(),
                function: FunctionCall {
                    name: tool.into(),
                    arguments: RawArguments::Obj(serde_json::json!({})),
                },
            }]),
            tool_call_id: None,
            name: None,
        }
    }

    impl ChatBackend for ScriptedBackend {
        async fn chat_once(
            &self,
            _model: &str,
            _messages: &[ChatMessage],
            _tools: &[Value],
            _options: &Map<String, Value>,
        ) -> Result<ChatMessage, crate::error::AppError> {
            *self.once_calls.lock().unwrap() += 1;
            let mut q = self.once.lock().unwrap();
            Ok(if q.is_empty() {
                assistant("done")
            } else {
                q.remove(0)
            })
        }

        async fn chat_stream(
            &self,
            _model: &str,
            _messages: &[ChatMessage],
            _options: &Map<String, Value>,
        ) -> Result<DeltaStream, crate::error::AppError> {
            let tokens = self.final_tokens.clone();
            let s = async_stream::stream! {
                for (i, t) in tokens.iter().enumerate() {
                    let last = i + 1 == tokens.len();
                    yield Ok(StreamDelta {
                        content: t.clone(),
                        done: last,
                        done_reason: if last { Some("stop".into()) } else { None },
                    });
                }
            };
            Ok(Box::pin(s))
        }
    }

    // ---- scripted tool executor ----

    #[derive(Clone)]
    struct ScriptedTools {
        schemas: Arc<Vec<Value>>,
        executed: Arc<Mutex<Vec<String>>>,
    }

    impl ToolExecutor for ScriptedTools {
        fn schemas(&self) -> Vec<Value> {
            (*self.schemas).clone()
        }
        async fn execute(
            &self,
            call: &ToolCall,
            _tx: mpsc::Sender<TurnEvent>,
            _cancel: CancellationToken,
        ) -> ToolOutcome {
            self.executed
                .lock()
                .unwrap()
                .push(call.function.name.clone());
            ToolOutcome {
                message: ChatMessage::tool_result("call_1", &call.function.name, "ok"),
                append_to_answer: None,
            }
        }
    }

    async fn drain(mut rx: mpsc::Receiver<TurnEvent>) -> Vec<TurnEvent> {
        let mut out = Vec::new();
        while let Some(e) = rx.recv().await {
            out.push(e);
        }
        out
    }

    fn cfg_with_iters(n: u8) -> Arc<Config> {
        // Minimal config; only fields the loop reads matter.
        let mut c = crate::config::tests_support::minimal();
        c.max_tool_iters = n;
        Arc::new(c)
    }

    fn collect_text(events: &[TurnEvent]) -> String {
        events
            .iter()
            .filter_map(|e| match e {
                TurnEvent::Token(t) => Some(t.clone()),
                _ => None,
            })
            .collect()
    }

    #[tokio::test]
    async fn fast_path_streams_without_tool_calls() {
        let backend = ScriptedBackend {
            once: Arc::new(Mutex::new(vec![])),
            once_calls: Arc::new(Mutex::new(0)),
            final_tokens: Arc::new(vec!["Hel".into(), "lo".into()]),
        };
        let tools = ScriptedTools {
            schemas: Arc::new(vec![]), // no tools -> fast path
            executed: Arc::new(Mutex::new(vec![])),
        };
        let (tx, rx) = mpsc::channel(64);
        run_turn(
            cfg_with_iters(5),
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(1)),
            vec![assistant("hi")],
            "m".into(),
            Map::new(),
            tx,
            CancellationToken::new(),
        )
        .await;
        let events = drain(rx).await;
        assert_eq!(collect_text(&events), "Hello");
        assert_eq!(
            *backend.once_calls.lock().unwrap(),
            0,
            "fast path skips chat_once"
        );
        assert!(matches!(events.last(), Some(TurnEvent::Done { .. })));
    }

    #[tokio::test]
    async fn tool_call_then_recall_then_stream() {
        let backend = ScriptedBackend {
            once: Arc::new(Mutex::new(vec![assistant_calling("web_search")])),
            once_calls: Arc::new(Mutex::new(0)),
            final_tokens: Arc::new(vec!["answer".into()]),
        };
        let executed = Arc::new(Mutex::new(vec![]));
        let tools = ScriptedTools {
            schemas: Arc::new(vec![serde_json::json!({"type":"function"})]),
            executed: executed.clone(),
        };
        let (tx, rx) = mpsc::channel(64);
        run_turn(
            cfg_with_iters(5),
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(1)),
            vec![assistant("hi")],
            "m".into(),
            Map::new(),
            tx,
            CancellationToken::new(),
        )
        .await;
        let events = drain(rx).await;
        assert_eq!(
            executed.lock().unwrap().as_slice(),
            &["web_search".to_string()]
        );
        // chat_once called twice: once -> tool_call, twice -> no tools (final)
        assert_eq!(*backend.once_calls.lock().unwrap(), 2);
        assert_eq!(collect_text(&events), "answer");
    }

    #[tokio::test]
    async fn iteration_cap_is_enforced() {
        // Model keeps requesting a tool forever; cap must stop the loop.
        let infinite = std::iter::repeat_with(|| assistant_calling("web_search"))
            .take(100)
            .collect::<Vec<_>>();
        let backend = ScriptedBackend {
            once: Arc::new(Mutex::new(infinite)),
            once_calls: Arc::new(Mutex::new(0)),
            final_tokens: Arc::new(vec!["capped".into()]),
        };
        let executed = Arc::new(Mutex::new(vec![]));
        let tools = ScriptedTools {
            schemas: Arc::new(vec![serde_json::json!({"type":"function"})]),
            executed: executed.clone(),
        };
        let (tx, rx) = mpsc::channel(256);
        run_turn(
            cfg_with_iters(3),
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(1)),
            vec![assistant("hi")],
            "m".into(),
            Map::new(),
            tx,
            CancellationToken::new(),
        )
        .await;
        let _ = drain(rx).await;
        // Exactly `max_tool_iters` chat_once calls, then a stream.
        assert_eq!(*backend.once_calls.lock().unwrap(), 3);
        assert_eq!(executed.lock().unwrap().len(), 3);
    }

    #[tokio::test]
    async fn cancellation_halts_before_streaming() {
        let backend = ScriptedBackend {
            once: Arc::new(Mutex::new(vec![])),
            once_calls: Arc::new(Mutex::new(0)),
            final_tokens: Arc::new(vec!["nope".into()]),
        };
        let tools = ScriptedTools {
            schemas: Arc::new(vec![]),
            executed: Arc::new(Mutex::new(vec![])),
        };
        let (tx, rx) = mpsc::channel(64);
        let cancel = CancellationToken::new();
        cancel.cancel(); // already cancelled
        run_turn(
            cfg_with_iters(5),
            backend,
            tools,
            Arc::new(Semaphore::new(1)),
            vec![assistant("hi")],
            "m".into(),
            Map::new(),
            tx,
            cancel,
        )
        .await;
        let events = drain(rx).await;
        assert!(collect_text(&events).is_empty(), "no tokens after cancel");
    }
}
