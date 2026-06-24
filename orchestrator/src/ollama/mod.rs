pub mod client;
pub mod types;

pub use client::OllamaClient;

use futures_util::Stream;
use serde_json::{Map, Value};

use crate::error::AppError;
use crate::openai::types::ChatMessage;

/// One delta from a streaming final-answer pass.
#[derive(Debug, Clone)]
pub struct StreamDelta {
    pub content: String,
    pub done: bool,
    pub done_reason: Option<String>,
}

/// A boxed stream of final-answer deltas (the streaming chat result).
pub type DeltaStream = std::pin::Pin<Box<dyn Stream<Item = Result<StreamDelta, AppError>> + Send>>;

/// The model backend the orchestrator talks to. Abstracted as a trait so the
/// tool loop can be unit-tested against a scripted in-memory backend with no
/// network (see `orchestrator::loop` tests).
pub trait ChatBackend: Send + Sync + Clone + 'static {
    /// Non-streaming chat used during tool resolution. Returns the assistant
    /// message (which may carry `tool_calls`).
    fn chat_once(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> impl std::future::Future<Output = Result<ChatMessage, AppError>> + Send;

    /// Streaming chat for the final answer (no tools offered).
    fn chat_stream(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> impl std::future::Future<Output = Result<DeltaStream, AppError>> + Send;
}
