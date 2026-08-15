//! Tool registry and the `ToolExecutor` abstraction.
//!
//! The turn loop is generic over `ToolExecutor` so it can be unit-tested with a
//! scripted executor. `ToolRegistry` is the production implementation: it owns
//! the HTTP client + config and dispatches to the concrete tool modules.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::future::Future;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::sse::ensure_call_id;
use crate::openai::types::{ChatMessage, RawArguments, ToolCall};
use crate::orchestrator::TurnEvent;
use crate::tools::{
    audio_gen, calculator, code_exec, code_exec_pool::CodeExecPools, github, image_edit, image_gen,
    maps_places, market_data, ocr, sports, time as time_tool, unit_convert, video_gen, weather,
    web_fetch, web_search,
};

/// Result of executing one tool call: the `tool`-role message to feed back to
/// the model, plus optional markdown to append to the final answer (used by
/// image generation to embed the produced image).
pub struct ToolOutcome {
    pub message: ChatMessage,
    pub append_to_answer: Option<String>,
    /// Whether this outcome is a folded-in failure (NFR-O6 keeps it non-fatal —
    /// the model reads it and continues). Metrics is the consumer: failures are
    /// otherwise invisible outside logs, and the message text is deliberately
    /// not sniffed (tools word their errors freely).
    pub is_error: bool,
}

/// A model-produced call after the common tool boundary has made it safe to
/// store and send to an upstream again. Invalid arguments become `{}` on the
/// wire, while `arguments_valid` keeps execution from using that replacement.
#[derive(Clone)]
pub(crate) struct GuardedToolCall {
    pub call: ToolCall,
    pub arguments_valid: bool,
}

/// Normalize tool-call ids and arguments before dispatch or history storage.
///
/// OpenAI-compatible hosts require `function.arguments` in assistant history
/// to contain a complete JSON object. Some models stream a truncated string.
/// Sending that string back makes strict hosts reject the recovery turn. Keep
/// the call/result pair valid by storing `{}` and folding a structured error
/// into the tool result instead. The placeholder is never executed. Empty
/// arguments are invalid too; only an explicit JSON object can run a tool.
pub(crate) fn guard_tool_calls(calls: Vec<ToolCall>) -> Vec<GuardedToolCall> {
    calls
        .into_iter()
        .map(|mut call| {
            call.id = Some(ensure_call_id(&call));
            let canonical = canonical_argument_object(&call.function.arguments);
            let arguments_valid = canonical.is_some();
            call.function.arguments = RawArguments::Str(canonical.unwrap_or_else(|| "{}".into()));

            if !arguments_valid {
                tracing::warn!(
                    tool = %call.function.name,
                    call_id = %call.id.as_deref().unwrap_or_default(),
                    "tool call rejected because arguments are not a complete JSON object"
                );
            }

            GuardedToolCall {
                call,
                arguments_valid,
            }
        })
        .collect()
}

fn canonical_argument_object(arguments: &RawArguments) -> Option<String> {
    let value = match arguments {
        RawArguments::Str(raw) => serde_json::from_str(raw).ok()?,
        RawArguments::Obj(value) => value.clone(),
    };
    value.is_object().then(|| value.to_string())
}

/// A safe model-visible result for a call rejected by [`guard_tool_calls`].
/// The original argument text is not included because it can contain user data.
pub(crate) fn invalid_arguments_outcome(call: &ToolCall) -> ToolOutcome {
    let content = json!({
        "ok": false,
        "error": {
            "code": "invalid_arguments",
            "retryable": true,
            "message": "Arguments must be one complete JSON object. Call the tool again with valid arguments."
        }
    })
    .to_string();
    ToolOutcome {
        message: ChatMessage::tool_result(
            call.id.as_deref().unwrap_or_default(),
            &call.function.name,
            content,
        ),
        append_to_answer: None,
        is_error: true,
    }
}

/// A within-turn dedup cache, shared (cheaply, behind `Arc<Mutex<_>>`) across
/// every tool call and research sub-agent in a single turn. It lives and dies
/// with the turn — it is never keyed by session and never outlives the request,
/// so it introduces no cross-turn server state (contract item 6 / XR-2). An
/// empty cache produces identical results; it only elides redundant work.
///
/// Two maps:
/// - `queries`: `query → formatted search output`, so the same search string is
///   not issued to Brave twice within one turn.
/// - `pages`: `url → extracted page text`, so the same page is not fetched and
///   extracted twice (e.g. when several sub-agents surface the same source).
///   A `None` value records a page we tried to fetch but that failed/timed out,
///   so we don't re-attempt a known-bad URL within the turn.
#[derive(Default)]
pub struct TurnCache {
    pub queries: HashMap<String, String>,
    pub pages: HashMap<String, Option<String>>,
}

/// Per-turn inputs a tool may need beyond its own arguments: the images the user
/// attached this turn (most recent last), so the edit tool can operate on "the
/// image I just sent" without the app naming it explicitly; whether this is a
/// Deep Research turn, which forces `web_search` to fetch full pages; and a
/// within-turn dedup cache so repeated queries/page-fetches are served once.
#[derive(Clone, Default)]
pub struct TurnContext {
    /// Editable images for this turn, most recent last, as raw base64 (data-URI
    /// prefixes stripped). Server-hosted `/v1/files/<id>/content` references in history
    /// are resolved to bytes here, so consuming tools (`image_edit`, `ocr`) see
    /// plain base64 regardless of how the image was delivered.
    pub input_images: Vec<String>,
    pub research: bool,
    /// Whether web access is enabled for this turn. Selects the code-exec lane: the
    /// internet-capable container when on, the no-network one when off. Defaults to
    /// off so a context built without it stays safe.
    pub web_access: bool,
    /// The server-hosted image store, when configured. Image tools persist to it
    /// and the turn loop resolves references against it. `None` => inline-only.
    pub images: Option<crate::images::BlobStore>,
    /// Whether to deliver generated images as store URLs rather than inline
    /// base64 — true only when a store exists *and* the client opted in.
    pub deliver_image_refs: bool,
    /// Within-turn fetch/query dedup cache (see [`TurnCache`]). Cloning a
    /// `TurnContext` shares the same cache (it's an `Arc`), so sub-agents that
    /// receive a cloned context still dedup against each other.
    pub cache: Arc<Mutex<TurnCache>>,
}

pub trait ToolExecutor: Send + Sync + Clone + 'static {
    /// JSON-Schema tool definitions offered to the model (empty => plain chat).
    fn schemas(&self) -> Vec<Value>;

    /// Record a call that the shared guard rejected before execution. Test and
    /// alternate executors need no bookkeeping, so their default is a no-op.
    fn record_guard_rejection(&self, _call: &ToolCall) {}

    /// Execute one tool call. Never returns an error: tool failures are folded
    /// into the returned `tool` message so the model can continue (NFR-O6).
    fn execute(
        &self,
        call: &ToolCall,
        ctx: &TurnContext,
        tx: mpsc::Sender<TurnEvent>,
        cancel: CancellationToken,
    ) -> impl Future<Output = ToolOutcome> + Send;
}

#[derive(Clone)]
pub struct ToolRegistry {
    cfg: Arc<Config>,
    http: reqwest::Client,
    /// Shared warm pools (offline + online lanes) for the code-exec tools (cloned
    /// in from `AppState`, never built here). `None` when disabled/unavailable.
    code_exec: Option<CodeExecPools>,
    /// Metrics registry; `execute` records every dispatch (count, latency,
    /// error) here — the one choke point all tool calls pass through.
    metrics: Arc<crate::metrics::Metrics>,
    /// The model driving this turn, for per-model tool attribution. The
    /// registry is built per turn (in `spawn_turn`), so one model per instance.
    model: String,
}

impl ToolRegistry {
    pub fn new(
        cfg: Arc<Config>,
        http: reqwest::Client,
        code_exec: Option<CodeExecPools>,
        metrics: Arc<crate::metrics::Metrics>,
        model: String,
    ) -> Self {
        ToolRegistry {
            cfg,
            http,
            code_exec,
            metrics,
            model,
        }
    }
}

/// Approximate prompt tokens contributed by each advertised server-tool schema.
/// The app has no model tokenizer, so use the same conservative four-byte
/// heuristic as its history compactor, plus a small per-tool envelope reserve.
/// Only `names` requested by the capability manifest are returned.
pub(crate) fn schema_token_estimates(
    cfg: &Config,
    names: &HashSet<String>,
) -> BTreeMap<String, u64> {
    configured_schemas(cfg, true)
        .into_iter()
        .filter_map(|schema| {
            let name = schema.get("function")?.get("name")?.as_str()?.to_string();
            if !names.contains(&name) {
                return None;
            }
            let bytes = serde_json::to_vec(&schema).ok()?.len() as u64;
            Some((name, bytes.div_ceil(4) + 16))
        })
        .collect()
}

fn configured_schemas(cfg: &Config, include_code_exec: bool) -> Vec<Value> {
    let mut out = Vec::new();
    if cfg.web_search_usable() {
        out.push(web_search::schema(cfg.search_thorough_usable()));
    }
    if cfg.web_fetch_usable() {
        out.push(web_fetch::schema());
    }
    if cfg.calculator_usable() {
        out.push(calculator::schema());
    }
    if cfg.time_usable() {
        out.push(time_tool::schema());
    }
    if cfg.unit_convert_usable() {
        out.push(unit_convert::schema());
    }
    if cfg.weather_usable() {
        out.push(weather::schema());
    }
    if cfg.sports_usable() {
        out.push(sports::schema());
    }
    if cfg.maps_places_usable() {
        out.push(maps_places::schema());
    }
    if cfg.market_data_usable() {
        out.push(market_data::schema());
    }
    if cfg.github_usable() {
        out.push(github::schema());
    }
    if cfg.ocr_usable() {
        out.push(ocr::schema());
    }
    if cfg.code_exec_usable() && include_code_exec {
        out.push(code_exec::schema(&cfg.code_exec_languages));
    }
    if cfg.image_gen_usable() {
        out.push(image_gen::schema());
    }
    if cfg.image_edit_usable() {
        out.push(image_edit::schema());
    }
    if cfg.audio_gen_usable() {
        out.push(audio_gen::schema());
    }
    if cfg.video_gen_usable() {
        out.push(video_gen::schema());
    }
    out
}

impl ToolExecutor for ToolRegistry {
    fn schemas(&self) -> Vec<Value> {
        // A single `code_exec` schema appears only when its warm pools exist.
        // Whether execution gets internet is selected later from `TurnContext`.
        configured_schemas(&self.cfg, self.code_exec.is_some())
    }

    fn record_guard_rejection(&self, call: &ToolCall) {
        self.metrics.record_tool_call(
            &call.function.name,
            true,
            &self.model,
            std::time::Duration::ZERO,
            true,
        );
    }

    async fn execute(
        &self,
        call: &ToolCall,
        ctx: &TurnContext,
        tx: mpsc::Sender<TurnEvent>,
        cancel: CancellationToken,
    ) -> ToolOutcome {
        let call_id = call.id.clone().unwrap_or_default();
        let name = call.function.name.as_str();

        // Per-tool-call observability (NFR-O7 safe): log the call, its argument
        // size, and the wall-clock it took. The argument *values* are only logged
        // when content logging is explicitly enabled, since they can echo user
        // input. Individual tools add their own `warn!` for the failure *cause*;
        // this records that the call happened and how long it took, uniformly.
        let started = std::time::Instant::now();
        let mut known = true;
        let arg_bytes = call.function.arguments.to_json_string().len();
        tracing::info!(tool = %name, call_id = %call_id, arg_bytes, "tool call started");
        if self.cfg.log_content {
            tracing::debug!(
                tool = %name,
                call_id = %call_id,
                args = %call.function.arguments.to_json_string(),
                "tool call arguments"
            );
        }

        let outcome = match name {
            "web_search" if self.cfg.web_search_usable() => {
                web_search::run(&self.cfg, &self.http, call, &call_id, ctx, &tx, &cancel).await
            }
            "web_fetch" if self.cfg.web_fetch_usable() => {
                web_fetch::run(&self.cfg, call, &call_id, ctx, &tx, &cancel).await
            }
            "calculator" if self.cfg.calculator_usable() => {
                calculator::run(call, &call_id, &tx, &cancel).await
            }
            "time" if self.cfg.time_usable() => time_tool::run(call, &call_id, &tx, &cancel).await,
            "unit_convert" if self.cfg.unit_convert_usable() => {
                unit_convert::run(call, &call_id, &tx, &cancel).await
            }
            "weather" if self.cfg.weather_usable() => {
                weather::run(&self.cfg, &self.http, call, &call_id, &tx, &cancel).await
            }
            "sports" if self.cfg.sports_usable() => {
                sports::run(&self.cfg, &self.http, call, &call_id, &tx, &cancel).await
            }
            "maps_places" if self.cfg.maps_places_usable() => {
                maps_places::run(&self.cfg, &self.http, call, &call_id, &tx, &cancel).await
            }
            "market_data" if self.cfg.market_data_usable() => {
                market_data::run(&self.cfg, &self.http, call, &call_id, &tx, &cancel).await
            }
            "github" if self.cfg.github_usable() => {
                github::run(&self.cfg, &self.http, call, &call_id, &tx, &cancel).await
            }
            "ocr" if self.cfg.ocr_usable() => {
                ocr::run(&self.cfg, call, &call_id, ctx, &tx, &cancel).await
            }
            "code_exec" if self.cfg.code_exec_usable() => match &self.code_exec {
                Some(pools) => {
                    // Internet only when web access is on this turn; otherwise the
                    // no-network lane.
                    let pool = if ctx.web_access {
                        &pools.online
                    } else {
                        &pools.offline
                    };
                    code_exec::run(&self.cfg, pool, call, &call_id, &tx, &cancel).await
                }
                None => ToolOutcome {
                    message: ChatMessage::tool_result(
                        &call_id,
                        "code_exec",
                        "code execution is not available",
                    ),
                    append_to_answer: None,
                    is_error: true,
                },
            },
            "image_generation" if self.cfg.image_gen_usable() => {
                image_gen::run(&self.cfg, &self.http, call, &call_id, ctx, &tx, &cancel).await
            }
            "image_edit" if self.cfg.image_edit_usable() => {
                image_edit::run(&self.cfg, &self.http, call, &call_id, ctx, &tx, &cancel).await
            }
            "audio_generation" if self.cfg.audio_gen_usable() => {
                audio_gen::run(&self.cfg, &self.http, call, &call_id, ctx, &tx, &cancel).await
            }
            "video_generation" if self.cfg.video_gen_usable() => {
                video_gen::run(&self.cfg, &self.http, call, &call_id, ctx, &tx, &cancel).await
            }
            other => {
                // Unknown / disabled tool: tell the model so it can recover.
                tracing::warn!(
                    tool = %other,
                    "model called an unknown or disabled tool"
                );
                known = false;
                let msg = format!("tool `{other}` is not available");
                ToolOutcome {
                    message: ChatMessage::tool_result(&call_id, other, msg),
                    append_to_answer: None,
                    is_error: true,
                }
            }
        };

        tracing::info!(
            tool = %name,
            call_id = %call_id,
            elapsed_ms = started.elapsed().as_millis() as u64,
            "tool call finished"
        );
        // `known` clamps model-invented names to the "other" metrics bucket.
        self.metrics.record_tool_call(
            name,
            known,
            &self.model,
            started.elapsed(),
            outcome.is_error,
        );
        outcome
    }
}

/// Build the OpenAI/Ollama function-tool envelope around a parameter schema.
pub fn tool_envelope(name: &str, description: &str, parameters: Value) -> Value {
    json!({
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": parameters,
        }
    })
}

#[cfg(test)]
mod guard_tests {
    use super::*;
    use crate::openai::types::FunctionCall;

    fn call(arguments: RawArguments) -> ToolCall {
        ToolCall {
            id: None,
            kind: "function".into(),
            function: FunctionCall {
                name: "test_tool".into(),
                arguments,
            },
        }
    }

    #[test]
    fn guard_canonicalizes_valid_argument_objects() {
        let guarded = guard_tool_calls(vec![
            call(RawArguments::Str("{ \"value\": 1 }".into())),
            call(RawArguments::Obj(json!({"value": 2}))),
        ]);

        assert!(guarded.iter().all(|call| call.arguments_valid));
        assert!(guarded.iter().all(|call| call.call.id.is_some()));
        assert_eq!(
            guarded[0].call.function.arguments.to_json_string(),
            r#"{"value":1}"#
        );
        assert_eq!(
            guarded[1].call.function.arguments.to_json_string(),
            r#"{"value":2}"#
        );
    }

    #[test]
    fn guard_rejects_incomplete_and_non_object_arguments() {
        let guarded = guard_tool_calls(vec![
            call(RawArguments::Str("  ".into())),
            call(RawArguments::Str(r#"{"value":"incomplete"#.into())),
            call(RawArguments::Str("[]".into())),
        ]);

        assert!(guarded.iter().all(|call| !call.arguments_valid));
        assert!(guarded
            .iter()
            .all(|call| call.call.function.arguments.to_json_string() == "{}"));
        let outcome = invalid_arguments_outcome(&guarded[0].call);
        let text = outcome
            .message
            .content
            .and_then(|content| content.into_text_and_images().0)
            .unwrap();
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["error"]["code"], "invalid_arguments");
        assert_eq!(value["error"]["retryable"], true);
    }
}
