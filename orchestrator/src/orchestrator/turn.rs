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

use std::collections::HashSet;
use std::sync::Arc;

use futures_util::StreamExt;
use serde_json::{Map, Value};
use tokio::sync::{mpsc, Semaphore};
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::ollama::ChatBackend;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{ToolExecutor, TurnContext};
use crate::orchestrator::{ResearchPreset, TurnEvent};

/// Map an internal server tool name to the app-facing capability that gates it.
/// Most tools map to themselves. `image_edit` rides under `image_generation`;
/// read-only utility/network tools ride under `web_search` so older app builds
/// that only know the broad web-tools toggle can still use newly-added tools.
fn capability_name(tool: &str) -> &str {
    match tool {
        "image_edit" => "image_generation",
        "web_fetch" | "calculator" | "unit_convert" | "weather" | "maps_places" | "market_data"
        | "github" | "ocr" => "web_search",
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

/// Read `function.name` out of an OpenAI tool-schema `Value`.
fn schema_name(schema: &Value) -> Option<String> {
    schema
        .get("function")
        .and_then(|f| f.get("name"))
        .and_then(Value::as_str)
        .map(String::from)
}

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
    app_tools: Vec<Value>,
    preset: Option<&'static ResearchPreset>,
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
                p = sem.clone().acquire_owned() => match p {
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

    // Deep Research: delegate to the orchestrator/worker engine, which drives its
    // own plan / isolated-sub-agent / synthesize / verify stages (each with its
    // own message context). Plain and ordinary tool turns keep the fast paths
    // below untouched (NFR-O3).
    //
    // Unlike a plain turn, a research run issues *many* upstream calls — fanned
    // out across concurrent sub-agents. Holding a single whole-run permit here
    // would under-count those calls and let `research_fanout_concurrency`
    // sub-agent calls run per permit, over-subscribing the GPU past
    // OLLAMA_MAX_CONCURRENCY (NFR-O2). So we drop the outer permit and hand the
    // semaphore to the engine, which re-acquires it per upstream call — keeping
    // total concurrent Ollama work across plain + research turns <= the global
    // bound. (Dropping first also avoids a self-deadlock: the engine's first
    // acquire would otherwise contend with the permit we still hold.)
    if let Some(p) = preset {
        drop(_permit);
        crate::orchestrator::research::run_research(
            cfg, backend, tools, sem, p, model, messages, options, tx, cancel,
        )
        .await;
        return;
    }

    // A plain turn honors the client's per-turn tool selection, then merges in
    // any app-hosted tools the request defined. On a name collision the server
    // tool wins (the app entry is dropped); `app_names` records which offered
    // tools must be forwarded to the app rather than executed here.
    let mut schemas = select_schemas(tools.schemas(), &enabled_tools);
    let server_names: HashSet<String> = schemas.iter().filter_map(schema_name).collect();
    let mut app_names: HashSet<String> = HashSet::new();
    for tool in app_tools {
        match schema_name(&tool) {
            Some(name) if !server_names.contains(&name) => {
                app_names.insert(name);
                schemas.push(tool);
            }
            _ => {} // unnamed, or collides with a server tool — drop it
        }
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
        research: false,
        ..Default::default()
    };

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
                // App-hosted tool calls are handed back to the app to execute;
                // the turn ends here. The app owns persistence of the assistant
                // tool_call message and the tool result, re-sending them next
                // turn (stateless, XR-2). Any co-occurring server calls are
                // dropped — the model re-issues them next turn once it has the
                // app's answer.
                let app_calls: Vec<ToolCall> = calls
                    .iter()
                    .filter(|c| app_names.contains(&c.function.name))
                    .cloned()
                    .collect();
                if !app_calls.is_empty() {
                    let _ = tx.send(TurnEvent::ToolCalls(app_calls)).await;
                    let _ = tx
                        .send(TurnEvent::Done {
                            reason: "tool_calls".into(),
                        })
                        .await;
                    return;
                }

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
    stream_relay_inner(backend, model, messages, options, appends, tx, cancel).await;
}

/// Stream a final-answer call and relay its tokens/reasoning, ending with a
/// `Done` event — the reusable streaming relay shared by the plain turn path and
/// the research synthesis stage (which appends nothing). Public to the crate so
/// `research.rs` can stream its synthesized answer through the same logic.
pub(crate) async fn stream_relay<B: ChatBackend>(
    backend: &B,
    model: &str,
    messages: &[ChatMessage],
    options: &Map<String, Value>,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) {
    stream_relay_inner(backend, model, messages, options, Vec::new(), tx, cancel).await;
}

async fn stream_relay_inner<B: ChatBackend>(
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
                if !delta.reasoning.is_empty()
                    && tx
                        .send(TurnEvent::Reasoning(delta.reasoning))
                        .await
                        .is_err()
                {
                    return; // client gone
                }
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
                    yield Ok(StreamDelta::content(
                        t.clone(),
                        last,
                        if last { Some("stop".into()) } else { None },
                    ));
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
            Vec::new(),
            None,
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
            Vec::new(),
            None,
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
            Vec::new(),
            None,
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
    async fn research_preset_delegates_to_engine_and_streams() {
        // A resolved research preset must DELEGATE to research::run_research,
        // not run the plain tool loop. The scripted backend's chat_once is used
        // for plan/sub-agent/compress/draft/verify; chat_stream is only reached
        // for the (non-verify) streaming synthesis, so a verify preset emits its
        // final answer as a Token (here the compress/verify echo "done"). The
        // key assertion is that we got a non-empty answer through the engine.
        let infinite = std::iter::repeat_with(|| assistant_calling("web_search"))
            .take(100)
            .collect::<Vec<_>>();
        let backend = ScriptedBackend::new(infinite, vec!["streamed".into()]);
        let executed = Arc::new(Mutex::new(vec![]));
        let tools = ScriptedTools {
            schemas: Arc::new(vec![
                named_schema("web_search"),
                named_schema("image_generation"),
            ]),
            executed: executed.clone(),
        };
        let (tx, rx) = mpsc::channel(256);
        let cfg = cfg_with_iters(2);
        let (_base, preset) = cfg.presets().resolve_model("m:quick-research");
        run_turn(
            cfg.clone(),
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(1)),
            vec![user(MessageContent::Text("compare X and Y".into()))],
            "m".into(),
            Map::new(),
            None,
            Vec::new(),
            preset,
            tx,
            CancellationToken::new(),
        )
        .await;
        let events = drain(rx).await;
        // quick-research has verify=false → synthesis STREAMS the answer.
        assert_eq!(collect_text(&events), "streamed");
        // Only web_search was ever executed (research narrows to its tool list),
        // proving the engine ran the isolated sub-agent loop.
        assert!(executed.lock().unwrap().iter().all(|t| t == "web_search"));
        // A planning heartbeat was emitted (engine entry, not the plain loop).
        assert!(events
            .iter()
            .any(|e| matches!(e, TurnEvent::Status(s) if s.contains("planning"))));
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
            Vec::new(),
            None,
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

    /// An app-hosted tool definition: a `tools` envelope that carries a
    /// `parameters` schema (which is what marks it app-side).
    fn app_schema(name: &str) -> Value {
        serde_json::json!({
            "type": "function",
            "function": {
                "name": name,
                "description": "app tool",
                "parameters": { "type": "object", "properties": {} }
            }
        })
    }

    fn assistant_calling_many(names: &[&str]) -> ChatMessage {
        ChatMessage {
            role: "assistant".into(),
            content: None,
            tool_calls: Some(
                names
                    .iter()
                    .enumerate()
                    .map(|(i, n)| ToolCall {
                        id: Some(format!("call_{i}")),
                        kind: "function".into(),
                        function: FunctionCall {
                            name: (*n).into(),
                            arguments: RawArguments::Obj(serde_json::json!({})),
                        },
                    })
                    .collect(),
            ),
            tool_call_id: None,
            name: None,
        }
    }

    /// The names in the first `ToolCalls` event, if any.
    fn forwarded_names(events: &[TurnEvent]) -> Vec<String> {
        events
            .iter()
            .find_map(|e| match e {
                TurnEvent::ToolCalls(calls) => {
                    Some(calls.iter().map(|c| c.function.name.clone()).collect())
                }
                _ => None,
            })
            .unwrap_or_default()
    }

    #[tokio::test]
    async fn app_tool_call_is_forwarded_not_executed() {
        let backend =
            ScriptedBackend::new(vec![assistant_calling("ask_user")], vec!["unused".into()]);
        let executed = Arc::new(Mutex::new(vec![]));
        let tools = ScriptedTools {
            schemas: Arc::new(vec![]), // no server tools
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
            vec![app_schema("ask_user")],
            None,
            tx,
            CancellationToken::new(),
        )
        .await;
        let events = drain(rx).await;
        assert_eq!(forwarded_names(&events), vec!["ask_user".to_string()]);
        assert!(
            matches!(events.last(), Some(TurnEvent::Done { reason }) if reason == "tool_calls"),
            "turn ends with finish_reason tool_calls"
        );
        assert!(
            executed.lock().unwrap().is_empty(),
            "app tool must not be executed server-side"
        );
        assert_eq!(
            *backend.once_calls.lock().unwrap(),
            1,
            "turn ends right after the forwarded call"
        );
    }

    #[tokio::test]
    async fn app_tool_colliding_with_server_tool_runs_server_side() {
        // The app defines a tool named like a configured server tool; server wins
        // — the call is executed here, never forwarded.
        let backend =
            ScriptedBackend::new(vec![assistant_calling("web_search")], vec!["answer".into()]);
        let executed = Arc::new(Mutex::new(vec![]));
        let tools = ScriptedTools {
            schemas: Arc::new(vec![named_schema("web_search")]),
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
            vec![app_schema("web_search")],
            None,
            tx,
            CancellationToken::new(),
        )
        .await;
        let events = drain(rx).await;
        assert!(
            forwarded_names(&events).is_empty(),
            "a colliding name is never forwarded"
        );
        assert_eq!(
            executed.lock().unwrap().as_slice(),
            &["web_search".to_string()]
        );
        assert_eq!(collect_text(&events), "answer");
    }

    #[tokio::test]
    async fn mixed_app_and_server_calls_forward_only_app() {
        // One assistant message calls both a server tool and an app tool: only the
        // app tool is forwarded; the server call is dropped this turn.
        let backend = ScriptedBackend::new(
            vec![assistant_calling_many(&["web_search", "ask_user"])],
            vec!["unused".into()],
        );
        let executed = Arc::new(Mutex::new(vec![]));
        let tools = ScriptedTools {
            schemas: Arc::new(vec![named_schema("web_search")]),
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
            vec![app_schema("ask_user")],
            None,
            tx,
            CancellationToken::new(),
        )
        .await;
        let events = drain(rx).await;
        assert_eq!(forwarded_names(&events), vec!["ask_user".to_string()]);
        assert!(
            executed.lock().unwrap().is_empty(),
            "co-occurring server call is dropped this turn"
        );
        assert!(
            matches!(events.last(), Some(TurnEvent::Done { reason }) if reason == "tool_calls")
        );
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
    fn select_schemas_maps_information_tools_to_web_search_capability() {
        let schemas = vec![
            named_schema("web_fetch"),
            named_schema("calculator"),
            named_schema("weather"),
            named_schema("image_generation"),
        ];
        let kept = select_schemas(schemas, &Some(vec!["web_search".into()]));
        assert_eq!(
            kept,
            vec![
                named_schema("web_fetch"),
                named_schema("calculator"),
                named_schema("weather"),
            ]
        );
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
            Vec::new(),
            None,
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
