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
use crate::orchestrator::tools::{ToolExecutor, TurnContext};
use crate::orchestrator::TurnEvent;

/// Map an internal server tool name to the app-facing capability that gates it.
/// Most tools map to themselves; `image_edit` rides under the `image_generation`
/// capability so the app needs no separate toggle (tools are invisible to the
/// app — the app's `x_tools` only ever names `image_generation`).
fn capability_name(tool: &str) -> &str {
    match tool {
        "image_edit" => "image_generation",
        other => other,
    }
}

/// Narrow a set of tool schemas to those the client asked for this turn.
///
/// `enabled` is the request's `x_tools` field: `None` => keep every schema
/// (older clients that don't select tools), `Some(list)` => keep only schemas
/// whose function name appears in the list (an empty list keeps none). The
/// schemas themselves already reflect what the server can actually run, so this
/// is purely a per-request narrowing — it can never add a tool.
pub fn select_schemas(schemas: Vec<Value>, enabled: &Option<Vec<String>>) -> Vec<Value> {
    let Some(allow) = enabled else {
        return schemas;
    };
    schemas
        .into_iter()
        .filter(|s| {
            s.get("function")
                .and_then(|f| f.get("name"))
                .and_then(Value::as_str)
                .is_some_and(|name| allow.iter().any(|a| a == capability_name(name)))
        })
        .collect()
}

/// System prompt injected for Deep Research turns (`x_research`). Drives the
/// decompose → reason-before-search → reflect → synthesize-with-citations loop.
const RESEARCH_SYSTEM_PROMPT: &str = "\
You are operating in Deep Research mode: the user wants a thorough, well-sourced \
answer, not a quick reply. Work in this order:\n\
1. Decompose the question into 3-5 focused sub-questions that together fully \
answer it. State them briefly before you start searching.\n\
2. Before each web_search call, say in one sentence what you are looking for and \
why.\n\
3. Use web_search to investigate the sub-questions, reading the returned pages.\n\
4. After each round of results, assess what is still missing and search again if \
needed. Don't stop until you can answer well, but don't run redundant searches.\n\
5. When you have enough, write one synthesized answer that directly answers the \
original question. Support claims with inline citations like [1], [2] that refer \
to the sources you actually used, and end with a numbered \"Sources\" list of \
those URLs.\n\
Cite only sources you genuinely used. Prefer recent, primary sources.";

#[allow(clippy::too_many_arguments)]
pub async fn run_turn<B, T>(
    cfg: Arc<Config>,
    backend: B,
    tools: T,
    sem: Arc<Semaphore>,
    mut messages: Vec<ChatMessage>,
    model: String,
    options: Map<String, Value>,
    enabled_tools: Option<Vec<String>>,
    research: bool,
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

    // Research mode offers only web_search (it's a focused search loop) and
    // prepends the research system prompt; otherwise honor the client's per-turn
    // tool selection.
    let schemas = if research {
        select_schemas(tools.schemas(), &Some(vec!["web_search".to_string()]))
    } else {
        select_schemas(tools.schemas(), &enabled_tools)
    };
    if research {
        messages.insert(0, ChatMessage::system(RESEARCH_SYSTEM_PROMPT));
    }

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
    let ctx = TurnContext {
        input_images: latest_input_images(&messages),
        research,
    };

    let max_iters = if research {
        cfg.max_research_iters
    } else {
        cfg.max_tool_iters
    };
    for _ in 0..max_iters {
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
                    let outcome = tools.execute(call, &ctx, tx.clone(), cancel.clone()).await;
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

/// Collect the image payloads from the most recent message that carries any —
/// whether the user attached it (`image_url` part) or the assistant generated
/// it earlier (embedded `data:` URI), most recent last. Lets the edit tool act
/// on "the image we were just looking at" without the model having to thread it
/// through tool arguments.
fn latest_input_images(messages: &[ChatMessage]) -> Vec<String> {
    messages
        .iter()
        .rev()
        .find_map(|m| {
            let images = m
                .content
                .as_ref()
                .map(|c| c.image_payloads())
                .unwrap_or_default();
            (!images.is_empty()).then_some(images)
        })
        .unwrap_or_default()
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
    use crate::openai::types::{ContentPart, FunctionCall, MessageContent, RawArguments, ToolCall};
    use crate::orchestrator::tools::ToolOutcome;
    use std::sync::Mutex;

    // ---- scripted backend ----

    #[derive(Clone)]
    struct ScriptedBackend {
        // Each chat_once call pops the next scripted assistant message.
        once: Arc<Mutex<Vec<ChatMessage>>>,
        once_calls: Arc<Mutex<usize>>,
        final_tokens: Arc<Vec<String>>,
        // Messages seen by the most recent chat_once call (for assertions).
        seen: Arc<Mutex<Vec<ChatMessage>>>,
    }

    impl ScriptedBackend {
        fn new(once: Vec<ChatMessage>, final_tokens: Vec<String>) -> Self {
            ScriptedBackend {
                once: Arc::new(Mutex::new(once)),
                once_calls: Arc::new(Mutex::new(0)),
                final_tokens: Arc::new(final_tokens),
                seen: Arc::new(Mutex::new(vec![])),
            }
        }
    }

    fn assistant(content: &str) -> ChatMessage {
        ChatMessage {
            role: "assistant".into(),
            content: Some(MessageContent::Text(content.into())),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    fn user(content: MessageContent) -> ChatMessage {
        ChatMessage {
            role: "user".into(),
            content: Some(content),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    fn user_with_image(b64: &str) -> ChatMessage {
        user(MessageContent::Parts(vec![ContentPart::ImageUrl {
            image_url: crate::openai::types::ImageUrl {
                url: format!("data:image/jpeg;base64,{b64}"),
            },
        }]))
    }

    #[test]
    fn latest_input_images_finds_generated_image_in_assistant_message() {
        // gen-then-edit: the image lives in the assistant message as markdown,
        // and the trailing user turn has no attachment.
        let history = vec![
            user(MessageContent::Text("draw a cat".into())),
            assistant("here you go ![generated](data:image/png;base64,GENGEN)"),
            user(MessageContent::Text("make it night".into())),
        ];
        assert_eq!(latest_input_images(&history), vec!["GENGEN".to_string()]);
    }

    #[test]
    fn latest_input_images_prefers_most_recent_across_roles() {
        let history = vec![
            assistant("![generated](data:image/png;base64,OLD)"),
            user_with_image("NEW"),
        ];
        assert_eq!(latest_input_images(&history), vec!["NEW".to_string()]);
    }

    #[test]
    fn latest_input_images_empty_when_no_image_anywhere() {
        let history = vec![user(MessageContent::Text("hi".into())), assistant("hello")];
        assert!(latest_input_images(&history).is_empty());
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
            *self.seen.lock().unwrap() = _messages.to_vec();
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
            _ctx: &TurnContext,
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

    fn cfg_research(tool_iters: u8, research_iters: u8) -> Arc<Config> {
        let mut c = crate::config::tests_support::minimal();
        c.max_tool_iters = tool_iters;
        c.max_research_iters = research_iters;
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
        let backend = ScriptedBackend::new(vec![], vec!["Hel".into(), "lo".into()]);
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
            None,
            false,
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
        let backend =
            ScriptedBackend::new(vec![assistant_calling("web_search")], vec!["answer".into()]);
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
            None,
            false,
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
        let backend = ScriptedBackend::new(infinite, vec!["capped".into()]);
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
            None,
            false,
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
    async fn research_mode_injects_prompt_and_uses_research_cap() {
        // Model keeps searching forever; the research cap (not max_tool_iters)
        // must bound the loop, and the research system prompt must be prepended.
        let infinite = std::iter::repeat_with(|| assistant_calling("web_search"))
            .take(100)
            .collect::<Vec<_>>();
        let backend = ScriptedBackend::new(infinite, vec!["report".into()]);
        let executed = Arc::new(Mutex::new(vec![]));
        let tools = ScriptedTools {
            schemas: Arc::new(vec![
                named_schema("web_search"),
                named_schema("image_generation"),
            ]),
            executed: executed.clone(),
        };
        let (tx, rx) = mpsc::channel(256);
        run_turn(
            cfg_research(2, 4), // tool cap 2, research cap 4
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(1)),
            vec![user(MessageContent::Text("compare X and Y".into()))],
            "m".into(),
            Map::new(),
            None,
            true, // research mode
            tx,
            CancellationToken::new(),
        )
        .await;
        let _ = drain(rx).await;
        // Research uses its own (larger) cap, not max_tool_iters (2).
        assert_eq!(*backend.once_calls.lock().unwrap(), 4);
        // The research system prompt is prepended as the first message.
        let seen = backend.seen.lock().unwrap();
        assert_eq!(seen.first().map(|m| m.role.as_str()), Some("system"));
    }

    #[tokio::test]
    async fn cancellation_halts_before_streaming() {
        let backend = ScriptedBackend::new(vec![], vec!["nope".into()]);
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
            None,
            false,
            tx,
            cancel,
        )
        .await;
        let events = drain(rx).await;
        assert!(collect_text(&events).is_empty(), "no tokens after cancel");
    }

    fn named_schema(name: &str) -> Value {
        serde_json::json!({ "type": "function", "function": { "name": name } })
    }

    #[test]
    fn select_schemas_keeps_all_when_unset() {
        let schemas = vec![named_schema("web_search"), named_schema("image_generation")];
        assert_eq!(select_schemas(schemas.clone(), &None), schemas);
    }

    #[test]
    fn select_schemas_filters_to_requested_names() {
        let schemas = vec![named_schema("web_search"), named_schema("image_generation")];
        let kept = select_schemas(schemas, &Some(vec!["web_search".into()]));
        assert_eq!(kept, vec![named_schema("web_search")]);
    }

    #[test]
    fn select_schemas_empty_list_keeps_none() {
        let schemas = vec![named_schema("web_search")];
        assert!(select_schemas(schemas, &Some(vec![])).is_empty());
    }

    #[tokio::test]
    async fn empty_tool_selection_takes_plain_fast_path() {
        // Tools are configured, but the client opted out via `x_tools: []` — the
        // turn must skip tool resolution entirely (no chat_once) and just stream.
        let backend =
            ScriptedBackend::new(vec![assistant_calling("web_search")], vec!["hi".into()]);
        let tools = ScriptedTools {
            schemas: Arc::new(vec![named_schema("web_search")]),
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
            Some(vec![]),
            false,
            tx,
            CancellationToken::new(),
        )
        .await;
        let events = drain(rx).await;
        assert_eq!(collect_text(&events), "hi");
        assert_eq!(
            *backend.once_calls.lock().unwrap(),
            0,
            "empty selection => fast path, no tool resolution"
        );
    }
}
