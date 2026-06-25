//! Tool registry and the `ToolExecutor` abstraction.
//!
//! The turn loop is generic over `ToolExecutor` so it can be unit-tested with a
//! scripted executor. `ToolRegistry` is the production implementation: it owns
//! the HTTP client + config and dispatches to the concrete tool modules.

use std::future::Future;
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::TurnEvent;
use crate::tools::{image_edit, image_gen, web_search};

/// Result of executing one tool call: the `tool`-role message to feed back to
/// the model, plus optional markdown to append to the final answer (used by
/// image generation to embed the produced image).
pub struct ToolOutcome {
    pub message: ChatMessage,
    pub append_to_answer: Option<String>,
}

/// Per-turn inputs a tool may need beyond its own arguments. Currently the
/// images the user attached this turn (most recent last), so the edit tool can
/// operate on "the image I just sent" without the app naming it explicitly.
#[derive(Clone, Default)]
pub struct TurnContext {
    pub input_images: Vec<String>,
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
            out.push(web_search::schema());
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
                web_search::run(&self.cfg, &self.http, call, &call_id, &tx, &cancel).await
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
