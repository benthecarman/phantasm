//! Hand-rolled async client for Ollama's native `/api/chat` (NDJSON) API.

use async_stream::try_stream;
use bytes::{Bytes, BytesMut};
use futures_util::{Stream, StreamExt};
use serde_json::{Map, Value};
use url::Url;

use super::types::{
    ModelMetadata, OllamaChatChunk, OllamaChatRequest, OllamaMessage, ShowResponse, TagsResponse,
};
use super::{ChatBackend, DeltaStream, StreamDelta};
use crate::error::AppError;
use crate::openai::types::ChatMessage;

/// Explicit residency hint for the opt-in warm preload path.
const WARM_KEEP_ALIVE: &str = "30m";

#[derive(Clone)]
pub struct OllamaClient {
    http: reqwest::Client,
    base: Url,
    /// Metrics registry for token-usage recording. Attached once at startup;
    /// `None` in tests and probes, which record nothing. Living here (not in
    /// the `ChatBackend` trait) keeps the trait — and its scripted test
    /// impls — untouched.
    metrics: Option<std::sync::Arc<crate::metrics::Metrics>>,
}

impl OllamaClient {
    pub fn new(http: reqwest::Client, base: Url) -> Self {
        OllamaClient {
            http,
            base,
            metrics: None,
        }
    }

    pub fn set_metrics(&mut self, metrics: std::sync::Arc<crate::metrics::Metrics>) {
        self.metrics = Some(metrics);
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
        keep_alive: Option<&str>,
    ) -> OllamaChatRequest {
        let mut options = options.clone();
        let think = extract_thinking_control(&mut options);
        options.remove("tool_choice");
        OllamaChatRequest {
            model: model.to_string(),
            messages: messages.iter().map(OllamaMessage::from_openai).collect(),
            tools: if tools.is_empty() {
                None
            } else {
                Some(tools.to_vec())
            },
            stream,
            think,
            options: if options.is_empty() {
                None
            } else {
                Some(Value::Object(options))
            },
            keep_alive: keep_alive.map(str::to_string),
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
            .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }

        let tags: TagsResponse = resp
            .json()
            .await
            .map_err(|e| AppError::UpstreamError(e.to_string()))?;
        Ok(tags.models.into_iter().map(|m| m.name).collect())
    }

    /// Declared metadata of a model via `/api/show` (e.g. capabilities and
    /// context window).
    pub async fn model_metadata(&self, model: &str) -> Result<ModelMetadata, AppError> {
        let url = self.endpoint("/api/show")?;
        let resp = self
            .http
            .post(url)
            .json(&serde_json::json!({ "model": model }))
            .send()
            .await
            .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }

        let show: ShowResponse = resp
            .json()
            .await
            .map_err(|e| AppError::UpstreamError(e.to_string()))?;
        Ok(show.into())
    }

    /// Declared capabilities of a model via `/api/show` (e.g. `"vision"`,
    /// `"tools"`). Used by focused tests and older internal callers.
    pub async fn model_capabilities(&self, model: &str) -> Result<Vec<String>, AppError> {
        Ok(self.model_metadata(model).await?.capabilities)
    }

    /// Best-effort model preload used only by `POST /v1/warm`.
    pub async fn warm_model(&self, model: &str) -> Result<(), AppError> {
        let url = self.endpoint("/api/chat")?;
        let body = self.build_request(model, &[], &[], &Map::new(), false, Some(WARM_KEEP_ALIVE));
        let resp = self
            .http
            .post(url)
            .json(&body)
            .send()
            .await
            .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }

        Ok(())
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
        let body = self.build_request(model, messages, tools, options, false, None);
        tracing::debug!(
            model = %model,
            messages = messages.len(),
            tools = tools.len(),
            "upstream chat_once (/api/chat, non-streaming)"
        );
        let resp = self.http.post(url).json(&body).send().await.map_err(|e| {
            tracing::warn!(model = %model, error = %e, "Ollama unreachable (chat_once)");
            AppError::UpstreamUnreachable(e.to_string())
        })?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            tracing::warn!(model = %model, %status, "Ollama returned error status (chat_once)");
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }

        let chunk: OllamaChatChunk = resp
            .json()
            .await
            .map_err(|e| AppError::UpstreamError(e.to_string()))?;
        record_chunk_usage(&usage_recorder(&self.metrics, model), &chunk);
        Ok(chunk.message.unwrap_or_default().into_openai())
    }

    async fn chat_stream(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> Result<DeltaStream, AppError> {
        let url = self.endpoint("/api/chat")?;
        let body = self.build_request(model, messages, &[], options, true, None);
        tracing::debug!(
            model = %model,
            messages = messages.len(),
            "upstream chat_stream (/api/chat, streaming)"
        );
        let resp = self.http.post(url).json(&body).send().await.map_err(|e| {
            tracing::warn!(model = %model, error = %e, "Ollama unreachable (chat_stream)");
            AppError::UpstreamUnreachable(e.to_string())
        })?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            tracing::warn!(model = %model, %status, "Ollama returned error status (chat_stream)");
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }

        let stream = ndjson_to_deltas(resp.bytes_stream(), usage_recorder(&self.metrics, model));
        Ok(Box::pin(stream))
    }
}

/// A metrics handle bound to the model of one request, for recording the
/// final chunk's generation stats. `None` => record nothing.
type UsageRecorder = Option<(std::sync::Arc<crate::metrics::Metrics>, String)>;

fn usage_recorder(
    metrics: &Option<std::sync::Arc<crate::metrics::Metrics>>,
    model: &str,
) -> UsageRecorder {
    metrics.as_ref().map(|m| (m.clone(), model.to_string()))
}

/// Feed a chunk's generation stats (present only on the final chunk) into the
/// registry. Intermediate chunks carry no counts and record nothing.
fn record_chunk_usage(recorder: &UsageRecorder, chunk: &OllamaChatChunk) {
    if let Some((metrics, model)) = recorder {
        metrics.record_usage(
            model,
            chunk.prompt_eval_count,
            chunk.eval_count,
            chunk.eval_duration,
            chunk.load_duration,
        );
    }
}

/// Turn a stream of raw byte chunks (NDJSON) into a stream of `StreamDelta`s,
/// buffering partial lines across chunk boundaries.
fn ndjson_to_deltas<S>(
    mut bytes: S,
    usage: UsageRecorder,
) -> impl Stream<Item = Result<StreamDelta, AppError>>
where
    S: Stream<Item = reqwest::Result<Bytes>> + Unpin,
{
    try_stream! {
        let mut buf = BytesMut::new();
        while let Some(next) = bytes.next().await {
            let chunk = next.map_err(|e| AppError::UpstreamError(e.to_string()))?;
            buf.extend_from_slice(&chunk);

            // Emit one delta per complete `\n`-terminated JSON line.
            while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line = buf.split_to(pos + 1);
                let trimmed = line.as_ref();
                if trimmed.iter().all(|b| b.is_ascii_whitespace()) {
                    continue;
                }
                let parsed: OllamaChatChunk = serde_json::from_slice(trimmed)
                    .map_err(|e| AppError::UpstreamError(format!("bad NDJSON line: {e}")))?;
                record_chunk_usage(&usage, &parsed);
                yield delta_from(parsed);
            }
        }

        // Flush any trailing line without a newline (defensive).
        let rest = buf.as_ref();
        if !rest.iter().all(|b| b.is_ascii_whitespace()) {
            if let Ok(parsed) = serde_json::from_slice::<OllamaChatChunk>(rest) {
                record_chunk_usage(&usage, &parsed);
                yield delta_from(parsed);
            }
        }
    }
}

fn delta_from(chunk: OllamaChatChunk) -> StreamDelta {
    let message = chunk.message.unwrap_or_default();
    StreamDelta::new(
        message.content.unwrap_or_default(),
        message.thinking.unwrap_or_default(),
        chunk.done,
        chunk.done_reason,
    )
}

/// Read the requested thinking control and strip the reasoning keys so they are
/// not forwarded to `/api/chat` (which expects the native `think` flag instead).
fn extract_thinking_control(options: &mut Map<String, Value>) -> Option<bool> {
    let think = crate::openai::types::requested_thinking(options)?;
    // Remove whichever key carried it (removing an absent key is a no-op).
    options.remove("reasoning_effort");
    options.remove("reasoning");
    Some(think)
}

#[cfg(test)]
mod tests {
    use super::{extract_thinking_control, ndjson_to_deltas, OllamaClient};
    use crate::error::AppError;
    use crate::ollama::StreamDelta;
    use bytes::Bytes;
    use futures_util::{stream, StreamExt};
    use serde_json::{json, Map, Value};
    use url::Url;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    async fn collect(chunks: Vec<reqwest::Result<Bytes>>) -> Vec<Result<StreamDelta, AppError>> {
        ndjson_to_deltas(stream::iter(chunks), None).collect().await
    }

    #[tokio::test]
    async fn ndjson_reassembles_line_split_across_chunks() {
        // One NDJSON object deliberately split mid-JSON, then a terminal line.
        let chunks: Vec<reqwest::Result<Bytes>> = vec![
            Ok(Bytes::from_static(b"{\"message\":{\"role\":\"assistant\",\"content\":\"He")),
            Ok(Bytes::from_static(
                b"llo\"},\"done\":false}\n{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\"}\n",
            )),
        ];
        let deltas: Vec<StreamDelta> = collect(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(deltas.len(), 2);
        assert_eq!(deltas[0].content, "Hello");
        assert!(!deltas[0].done);
        assert!(deltas[1].done);
        assert_eq!(deltas[1].done_reason.as_deref(), Some("stop"));
    }

    #[tokio::test]
    async fn ndjson_carries_thinking_as_reasoning() {
        let chunks = vec![Ok(Bytes::from_static(
            b"{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"thinking\":\"hmm\"},\"done\":false}\n",
        ))];
        let deltas: Vec<StreamDelta> = collect(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0].reasoning, "hmm");
    }

    #[tokio::test]
    async fn ndjson_flushes_trailing_line_without_newline() {
        // A final object arriving without its terminating newline is still emitted.
        let chunks = vec![Ok(Bytes::from_static(
            b"{\"message\":{\"role\":\"assistant\",\"content\":\"tail\"},\"done\":true}",
        ))];
        let deltas: Vec<StreamDelta> = collect(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0].content, "tail");
        assert!(deltas[0].done);
    }

    #[tokio::test]
    async fn ndjson_skips_blank_lines() {
        let chunks = vec![Ok(Bytes::from_static(
            b"\n{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"done\":false}\n\n",
        ))];
        let deltas: Vec<StreamDelta> = collect(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0].content, "x");
    }

    #[tokio::test]
    async fn ndjson_final_chunk_records_usage() {
        let metrics = crate::metrics::Metrics::without_store();
        let chunks: Vec<reqwest::Result<Bytes>> = vec![Ok(Bytes::from_static(
            b"{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"done\":false}\n\
              {\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\
               \"prompt_eval_count\":10,\"eval_count\":30,\"eval_duration\":1500000000,\"load_duration\":2000000000}\n",
        ))];
        let deltas: Vec<StreamDelta> =
            ndjson_to_deltas(stream::iter(chunks), Some((metrics.clone(), "m1".into())))
                .collect::<Vec<_>>()
                .await
                .into_iter()
                .map(|r| r.unwrap())
                .collect();
        assert_eq!(deltas.len(), 2);
        let stats = metrics.model("m1");
        assert_eq!(stats.prompt_tokens.get(), 10);
        assert_eq!(stats.completion_tokens.get(), 30);
        // 30 tokens / 1.5s = 20 tok/s.
        assert_eq!(stats.tokens_per_sec.snapshot().count, 1);
        assert_eq!(stats.model_load.snapshot().count, 1);
    }

    #[tokio::test]
    async fn ndjson_surfaces_malformed_line_as_error() {
        let chunks = vec![Ok(Bytes::from_static(b"{not json}\n"))];
        let first = collect(chunks).await.into_iter().next().expect("one item");
        assert!(matches!(first, Err(AppError::UpstreamError(_))));
    }

    #[tokio::test]
    async fn model_metadata_surfaces_non_success_show_status() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(ResponseTemplate::new(404).set_body_json(json!({
                "error": "missing model"
            })))
            .mount(&server)
            .await;
        let client = OllamaClient::new(
            reqwest::Client::new(),
            Url::parse(&server.uri()).expect("mock server URL"),
        );

        let err = client
            .model_metadata("missing")
            .await
            .expect_err("non-2xx /api/show should fail");

        match err {
            AppError::UpstreamError(message) => {
                assert!(message.contains("404"), "status should be preserved");
                assert!(
                    message.contains("missing model"),
                    "response body should be preserved"
                );
            }
            other => panic!("expected UpstreamError, got {other:?}"),
        }
    }

    #[test]
    fn reasoning_effort_none_maps_to_think_false() {
        let mut options = Map::from_iter([
            ("reasoning_effort".into(), Value::String("none".into())),
            ("temperature".into(), json!(0.2)),
        ]);

        assert_eq!(extract_thinking_control(&mut options), Some(false));
        assert!(!options.contains_key("reasoning_effort"));
        assert_eq!(options.get("temperature"), Some(&json!(0.2)));
    }

    #[test]
    fn reasoning_effort_value_maps_to_think_true() {
        let mut options = Map::from_iter([
            ("reasoning_effort".into(), Value::String("medium".into())),
            ("temperature".into(), json!(0.2)),
        ]);

        assert_eq!(extract_thinking_control(&mut options), Some(true));
        assert!(!options.contains_key("reasoning_effort"));
        assert_eq!(options.get("temperature"), Some(&json!(0.2)));
    }

    #[test]
    fn nested_reasoning_none_maps_to_think_false() {
        let mut options = Map::from_iter([("reasoning".into(), json!({ "effort": "none" }))]);

        assert_eq!(extract_thinking_control(&mut options), Some(false));
        assert!(!options.contains_key("reasoning"));
    }

    #[test]
    fn nested_reasoning_value_maps_to_think_true() {
        let mut options = Map::from_iter([("reasoning".into(), json!({ "effort": "medium" }))]);

        assert_eq!(extract_thinking_control(&mut options), Some(true));
        assert!(!options.contains_key("reasoning"));
    }
}
