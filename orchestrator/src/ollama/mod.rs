pub mod client;
pub mod types;
mod xml_tools;

pub use client::OllamaClient;

use futures_util::Stream;
use serde_json::{Map, Value};

use crate::config::UpstreamSpec;
use crate::error::AppError;
use crate::ollama::types::ModelMetadata;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::openai::OpenAICompatibleClient;

/// One delta from a streaming final-answer pass.
#[derive(Debug, Clone)]
pub struct StreamDelta {
    pub content: String,
    pub reasoning: String,
    pub done: bool,
    pub done_reason: Option<String>,
}

impl StreamDelta {
    pub fn new(
        content: impl Into<String>,
        reasoning: impl Into<String>,
        done: bool,
        done_reason: Option<String>,
    ) -> Self {
        StreamDelta {
            content: content.into(),
            reasoning: reasoning.into(),
            done,
            done_reason,
        }
    }

    pub fn content(content: impl Into<String>, done: bool, done_reason: Option<String>) -> Self {
        Self::new(content, "", done, done_reason)
    }
}

/// A boxed stream of final-answer deltas (the streaming chat result).
pub type DeltaStream = std::pin::Pin<Box<dyn Stream<Item = Result<StreamDelta, AppError>> + Send>>;

/// One delta from a streaming tool-resolution pass. OpenAI-compatible upstreams
/// can stream either final-answer content or a terminal tool-call batch.
#[derive(Debug, Clone)]
pub struct ToolStreamDelta {
    pub content: String,
    pub reasoning: String,
    pub tool_calls: Option<Vec<ToolCall>>,
    pub done: bool,
    pub done_reason: Option<String>,
}

impl ToolStreamDelta {
    pub fn new(
        content: impl Into<String>,
        reasoning: impl Into<String>,
        tool_calls: Option<Vec<ToolCall>>,
        done: bool,
        done_reason: Option<String>,
    ) -> Self {
        ToolStreamDelta {
            content: content.into(),
            reasoning: reasoning.into(),
            tool_calls,
            done,
            done_reason,
        }
    }
}

pub type ToolDeltaStream =
    std::pin::Pin<Box<dyn Stream<Item = Result<ToolStreamDelta, AppError>> + Send>>;

/// The model backend the orchestrator talks to. Abstracted as a trait so the
/// tool loop can be unit-tested against a scripted in-memory backend with no
/// network (see `orchestrator::loop` tests).
pub trait ChatBackend: Send + Sync + Clone + 'static {
    /// Non-streaming chat used for non-streaming downstream requests and
    /// research-internal planning calls. Streaming turns do not use this for
    /// tool resolution.
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

    /// Streaming final answer for a turn that just exhausted its tool budget.
    /// Same call shape as [`Self::chat_stream`], but the model was being
    /// offered tools until this very call, so backends that can should excise
    /// text-formatted tool-call blocks (see `ollama::xml_tools`) instead of
    /// relaying them as answer text — they are call attempts that can no
    /// longer be executed. Default: plain `chat_stream` (verbatim relay).
    fn chat_stream_after_tools(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> impl std::future::Future<Output = Result<DeltaStream, AppError>> + Send {
        self.chat_stream(model, messages, options)
    }

    /// Streaming tool-resolution pass. Streaming chat turns require this; a
    /// backend returning `Ok(None)` fails the turn rather than taking a hidden
    /// non-streaming fallback.
    fn chat_stream_tools(
        &self,
        _model: &str,
        _messages: &[ChatMessage],
        _tools: &[Value],
        _options: &Map<String, Value>,
    ) -> impl std::future::Future<Output = Result<Option<ToolDeltaStream>, AppError>> + Send {
        async { Ok(None) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpstreamKind {
    NativeOllama,
    OpenAICompatible,
}

#[derive(Clone)]
pub enum UpstreamChatBackend {
    NativeOllama(OllamaClient),
    OpenAICompatible(OpenAICompatibleClient),
}

impl UpstreamChatBackend {
    pub fn from_spec(kind: UpstreamKind, http: reqwest::Client, spec: &UpstreamSpec) -> Self {
        match kind {
            UpstreamKind::NativeOllama => {
                let mut client = OllamaClient::new(http, spec.base.clone());
                client.set_num_ctx_cap(spec.num_ctx_cap);
                UpstreamChatBackend::NativeOllama(client)
            }
            UpstreamKind::OpenAICompatible => {
                UpstreamChatBackend::OpenAICompatible(OpenAICompatibleClient::new(
                    http,
                    &spec.base,
                    spec.api_key.as_deref(),
                    spec.thinking_hint,
                ))
            }
        }
    }

    /// Attach the metrics registry so both client kinds record token usage
    /// where they already parse upstream responses. Called once at startup;
    /// kept off the `ChatBackend` trait so scripted test impls stay untouched.
    pub fn attach_metrics(&mut self, metrics: std::sync::Arc<crate::metrics::Metrics>) {
        match self {
            UpstreamChatBackend::NativeOllama(client) => client.set_metrics(metrics),
            UpstreamChatBackend::OpenAICompatible(client) => client.set_metrics(metrics),
        }
    }

    pub fn kind(&self) -> UpstreamKind {
        match self {
            UpstreamChatBackend::NativeOllama(_) => UpstreamKind::NativeOllama,
            UpstreamChatBackend::OpenAICompatible(_) => UpstreamKind::OpenAICompatible,
        }
    }

    pub async fn list_models(&self) -> Result<Vec<String>, AppError> {
        match self {
            UpstreamChatBackend::NativeOllama(client) => client.list_models().await,
            UpstreamChatBackend::OpenAICompatible(client) => client.list_models().await,
        }
    }

    pub async fn model_metadata(&self, model: &str) -> Option<Result<ModelMetadata, AppError>> {
        match self {
            UpstreamChatBackend::NativeOllama(client) => Some(client.model_metadata(model).await),
            UpstreamChatBackend::OpenAICompatible(_) => None,
        }
    }

    pub async fn warm_model(&self, model: &str) -> Result<bool, AppError> {
        match self {
            UpstreamChatBackend::NativeOllama(client) => {
                client.warm_model(model).await.map(|()| true)
            }
            UpstreamChatBackend::OpenAICompatible(_) => Ok(false),
        }
    }
}

impl ChatBackend for UpstreamChatBackend {
    async fn chat_once(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> Result<ChatMessage, AppError> {
        match self {
            UpstreamChatBackend::NativeOllama(client) => {
                client.chat_once(model, messages, tools, options).await
            }
            UpstreamChatBackend::OpenAICompatible(client) => {
                client.chat_once(model, messages, tools, options).await
            }
        }
    }

    async fn chat_stream(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> Result<DeltaStream, AppError> {
        match self {
            UpstreamChatBackend::NativeOllama(client) => {
                client.chat_stream(model, messages, options).await
            }
            UpstreamChatBackend::OpenAICompatible(client) => {
                client.chat_stream(model, messages, options).await
            }
        }
    }

    async fn chat_stream_after_tools(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> Result<DeltaStream, AppError> {
        match self {
            UpstreamChatBackend::NativeOllama(client) => {
                client
                    .chat_stream_after_tools(model, messages, options)
                    .await
            }
            // No XML fallback for OpenAI-compatible upstreams yet — verbatim,
            // matching their chat_stream (tracked as a separate port).
            UpstreamChatBackend::OpenAICompatible(client) => {
                client.chat_stream(model, messages, options).await
            }
        }
    }

    async fn chat_stream_tools(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> Result<Option<ToolDeltaStream>, AppError> {
        match self {
            UpstreamChatBackend::NativeOllama(client) => {
                client
                    .chat_stream_tools(model, messages, tools, options)
                    .await
            }
            UpstreamChatBackend::OpenAICompatible(client) => {
                client
                    .chat_stream_tools(model, messages, tools, options)
                    .await
            }
        }
    }
}
