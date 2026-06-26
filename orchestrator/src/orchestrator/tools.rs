//! Tool registry and the `ToolExecutor` abstraction.
//!
//! The turn loop is generic over `ToolExecutor` so it can be unit-tested with a
//! scripted executor. `ToolRegistry` is the production implementation: it owns
//! the HTTP client + config and dispatches to the concrete tool modules.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::TurnEvent;
use crate::tools::{
    calculator, current_time, github, image_edit, image_gen, maps_places, market_data, ocr,
    unit_convert, weather, web_fetch, web_search,
};

/// Result of executing one tool call: the `tool`-role message to feed back to
/// the model, plus optional markdown to append to the final answer (used by
/// image generation to embed the produced image).
pub struct ToolOutcome {
    pub message: ChatMessage,
    pub append_to_answer: Option<String>,
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
    pub input_images: Vec<String>,
    pub research: bool,
    /// Within-turn fetch/query dedup cache (see [`TurnCache`]). Cloning a
    /// `TurnContext` shares the same cache (it's an `Arc`), so sub-agents that
    /// receive a cloned context still dedup against each other.
    pub cache: Arc<Mutex<TurnCache>>,
}

pub trait ToolExecutor: Send + Sync + Clone + 'static {
    /// JSON-Schema tool definitions offered to the model (empty => plain chat).
    fn schemas(&self) -> Vec<Value>;

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
}

impl ToolRegistry {
    pub fn new(cfg: Arc<Config>, http: reqwest::Client) -> Self {
        ToolRegistry { cfg, http }
    }
}

impl ToolExecutor for ToolRegistry {
    fn schemas(&self) -> Vec<Value> {
        let mut out = Vec::new();
        if self.cfg.web_search_usable() {
            out.push(web_search::schema(self.cfg.search_thorough_usable()));
        }
        if self.cfg.web_fetch_usable() {
            out.push(web_fetch::schema());
        }
        if self.cfg.current_time_usable() {
            out.push(current_time::schema());
        }
        if self.cfg.calculator_usable() {
            out.push(calculator::schema());
        }
        if self.cfg.unit_convert_usable() {
            out.push(unit_convert::schema());
        }
        if self.cfg.weather_usable() {
            out.push(weather::schema());
        }
        if self.cfg.maps_places_usable() {
            out.push(maps_places::schema());
        }
        if self.cfg.market_data_usable() {
            out.push(market_data::schema());
        }
        if self.cfg.github_usable() {
            out.push(github::schema());
        }
        if self.cfg.ocr_usable() {
            out.push(ocr::schema());
        }
        if self.cfg.image_gen_usable() {
            out.push(image_gen::schema());
        }
        if self.cfg.image_edit_usable() {
            out.push(image_edit::schema());
        }
        out
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

        match name {
            "web_search" if self.cfg.web_search_usable() => {
                web_search::run(&self.cfg, &self.http, call, &call_id, ctx, &tx, &cancel).await
            }
            "web_fetch" if self.cfg.web_fetch_usable() => {
                web_fetch::run(&self.cfg, &self.http, call, &call_id, ctx, &tx, &cancel).await
            }
            "current_time" if self.cfg.current_time_usable() => {
                current_time::run(call, &call_id, &tx, &cancel).await
            }
            "calculator" if self.cfg.calculator_usable() => {
                calculator::run(call, &call_id, &tx, &cancel).await
            }
            "unit_convert" if self.cfg.unit_convert_usable() => {
                unit_convert::run(call, &call_id, &tx, &cancel).await
            }
            "weather" if self.cfg.weather_usable() => {
                weather::run(&self.cfg, &self.http, call, &call_id, &tx, &cancel).await
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
            "image_generation" if self.cfg.image_gen_usable() => {
                image_gen::run(&self.cfg, &self.http, call, &call_id, &tx, &cancel).await
            }
            "image_edit" if self.cfg.image_edit_usable() => {
                image_edit::run(&self.cfg, &self.http, call, &call_id, ctx, &tx, &cancel).await
            }
            other => {
                // Unknown / disabled tool: tell the model so it can recover.
                let msg = format!("tool `{other}` is not available");
                ToolOutcome {
                    message: ChatMessage::tool_result(call_id, other, msg),
                    append_to_answer: None,
                }
            }
        }
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
