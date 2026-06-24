//! Hand-rolled async client for Ollama's native `/api/chat` (NDJSON) API.

use async_stream::try_stream;
use bytes::{Bytes, BytesMut};
use futures_util::{Stream, StreamExt};
use serde_json::{Map, Value};
use url::Url;

use super::types::{OllamaChatChunk, OllamaChatRequest, OllamaMessage, TagsResponse};
use super::{ChatBackend, DeltaStream, StreamDelta};
use crate::error::AppError;
use crate::openai::types::ChatMessage;

/// Keep models resident across turns for KV-cache reuse (NFR-O8).
const KEEP_ALIVE: &str = "30m";

#[derive(Clone)]
pub struct OllamaClient {
    http: reqwest::Client,
    base: Url,
}

impl OllamaClient {
    pub fn new(http: reqwest::Client, base: Url) -> Self {
        OllamaClient { http, base }
    }

    fn endpoint(&self, path: &str) -> Result<Url, AppError> {
        self.base
            .join(path)
            .map_err(|e| AppError::Internal(format!("bad Ollama URL: {e}")))
    }

    fn build_request(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
        stream: bool,
    ) -> OllamaChatRequest {
        OllamaChatRequest {
            model: model.to_string(),
            messages: messages.iter().map(OllamaMessage::from_openai).collect(),
            tools: if tools.is_empty() {
                None
            } else {
                Some(tools.to_vec())
            },
            stream,
            options: if options.is_empty() {
                None
            } else {
                Some(Value::Object(options.clone()))
            },
            keep_alive: Some(KEEP_ALIVE.to_string()),
        }
    }

    /// List locally available models via `/api/tags`. Used for capabilities.
    pub async fn list_models(&self) -> Result<Vec<String>, AppError> {
        let url = self.endpoint("/api/tags")?;
        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| AppError::OllamaUnreachable(e.to_string()))?;
        let tags: TagsResponse = resp
            .json()
            .await
            .map_err(|e| AppError::OllamaError(e.to_string()))?;
        Ok(tags.models.into_iter().map(|m| m.name).collect())
    }
}

impl ChatBackend for OllamaClient {
    async fn chat_once(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> Result<ChatMessage, AppError> {
        let url = self.endpoint("/api/chat")?;
        let body = self.build_request(model, messages, tools, options, false);
        let resp = self
            .http
            .post(url)
            .json(&body)
            .send()
            .await
            .map_err(|e| AppError::OllamaUnreachable(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::OllamaError(format!("{status}: {detail}")));
        }

        let chunk: OllamaChatChunk = resp
            .json()
            .await
            .map_err(|e| AppError::OllamaError(e.to_string()))?;
        Ok(chunk.message.unwrap_or_default().into_openai())
    }

    async fn chat_stream(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> Result<DeltaStream, AppError> {
        let url = self.endpoint("/api/chat")?;
        let body = self.build_request(model, messages, &[], options, true);
        let resp = self
            .http
            .post(url)
            .json(&body)
            .send()
            .await
            .map_err(|e| AppError::OllamaUnreachable(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::OllamaError(format!("{status}: {detail}")));
        }

        let stream = ndjson_to_deltas(resp.bytes_stream());
        Ok(Box::pin(stream))
    }
}

/// Turn a stream of raw byte chunks (NDJSON) into a stream of `StreamDelta`s,
/// buffering partial lines across chunk boundaries.
fn ndjson_to_deltas<S>(mut bytes: S) -> impl Stream<Item = Result<StreamDelta, AppError>>
where
    S: Stream<Item = reqwest::Result<Bytes>> + Unpin,
{
    try_stream! {
        let mut buf = BytesMut::new();
        while let Some(next) = bytes.next().await {
            let chunk = next.map_err(|e| AppError::OllamaError(e.to_string()))?;
            buf.extend_from_slice(&chunk);

            // Emit one delta per complete `\n`-terminated JSON line.
            while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line = buf.split_to(pos + 1);
                let trimmed = line.as_ref();
                if trimmed.iter().all(|b| b.is_ascii_whitespace()) {
                    continue;
                }
                let parsed: OllamaChatChunk = serde_json::from_slice(trimmed)
                    .map_err(|e| AppError::OllamaError(format!("bad NDJSON line: {e}")))?;
                yield delta_from(parsed);
            }
        }

        // Flush any trailing line without a newline (defensive).
        let rest = buf.as_ref();
        if !rest.iter().all(|b| b.is_ascii_whitespace()) {
            if let Ok(parsed) = serde_json::from_slice::<OllamaChatChunk>(rest) {
                yield delta_from(parsed);
            }
        }
    }
}

fn delta_from(chunk: OllamaChatChunk) -> StreamDelta {
    let content = chunk.message.and_then(|m| m.content).unwrap_or_default();
    StreamDelta {
        content,
        done: chunk.done,
        done_reason: chunk.done_reason,
    }
}
