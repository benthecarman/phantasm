//! OpenAI-compatible upstream chat client.
//!
//! This is used when startup probing finds `/v1/models` but not Ollama's
//! native `/api/tags`. The downstream app contract remains our own
//! OpenAI-compatible endpoint; this client is only for model-host traffic.

use async_stream::try_stream;
use bytes::{Bytes, BytesMut};
use futures_util::{Stream, StreamExt};
use secrecy::{ExposeSecret, SecretString};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;
use url::Url;

use crate::error::AppError;
use crate::ollama::{ChatBackend, DeltaStream, StreamDelta, ToolDeltaStream, ToolStreamDelta};
use crate::openai::types::{
    requested_thinking, ChatMessage, FunctionCall, MessageContent, RawArguments, ToolCall,
};

#[derive(Clone)]
pub struct OpenAICompatibleClient {
    http: reqwest::Client,
    /// Already normalized to end in `/v1` (no trailing slash) by [`openai_api_base`].
    api_base: String,
    /// Bearer token sent on every request, when the deployment requires one.
    api_key: Option<SecretString>,
    /// Whether to send the Qwen-style `chat_template_kwargs.enable_thinking` hint.
    /// On for template-driven hosts (vLLM/llama.cpp); a deployment pointing at a
    /// strict `/v1` server that rejects unknown body fields turns it off.
    thinking_hint: bool,
    /// Metrics registry for token-usage recording. OpenAI-compatible hosts that
    /// honor `stream_options.include_usage` report final streaming token counts;
    /// for those we use the observed stream duration as the throughput window.
    metrics: Option<Arc<crate::metrics::Metrics>>,
}

impl OpenAICompatibleClient {
    pub fn new(
        http: reqwest::Client,
        base: &Url,
        api_key: Option<&str>,
        thinking_hint: bool,
    ) -> Self {
        let api_key = api_key
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| SecretString::from(s.to_string()));
        OpenAICompatibleClient {
            http,
            api_base: openai_api_base(base),
            api_key,
            thinking_hint,
            metrics: None,
        }
    }

    pub fn set_metrics(&mut self, metrics: Arc<crate::metrics::Metrics>) {
        self.metrics = Some(metrics);
    }

    /// A POST builder carrying the bearer token when one is configured.
    fn authed_post(&self, url: &str) -> reqwest::RequestBuilder {
        let req = self.http.post(url);
        match &self.api_key {
            Some(key) => req.bearer_auth(key.expose_secret()),
            None => req,
        }
    }

    /// A GET builder carrying the bearer token when one is configured.
    fn authed_get(&self, url: &str) -> reqwest::RequestBuilder {
        let req = self.http.get(url);
        match &self.api_key {
            Some(key) => req.bearer_auth(key.expose_secret()),
            None => req,
        }
    }

    pub async fn list_models(&self) -> Result<Vec<String>, AppError> {
        list_models_response(self.authed_get(&self.models_url())).await
    }

    fn build_request(
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
        stream: bool,
        thinking_hint: bool,
    ) -> Value {
        let mut body = options.clone();
        if thinking_hint {
            apply_chat_template_thinking_hint(&mut body);
        }
        body.insert("model".into(), Value::String(model.to_string()));
        body.insert("messages".into(), messages_value(messages));
        body.insert("stream".into(), Value::Bool(stream));
        if stream {
            body.entry("stream_options").or_insert_with(|| {
                json!({
                    "include_usage": true
                })
            });
        }
        if !tools.is_empty() {
            body.insert("tools".into(), Value::Array(tools.to_vec()));
        } else {
            body.remove("tool_choice");
        }
        Value::Object(body)
    }

    fn chat_url(&self) -> String {
        format!("{}/chat/completions", self.api_base)
    }

    fn models_url(&self) -> String {
        format!("{}/models", self.api_base)
    }
}

async fn list_models_response(req: reqwest::RequestBuilder) -> Result<Vec<String>, AppError> {
    let resp = req
        .send()
        .await
        .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let detail = resp.text().await.unwrap_or_default();
        return Err(AppError::UpstreamError(format!("{status}: {detail}")));
    }
    let models: ModelsResponse = resp
        .json()
        .await
        .map_err(|e| AppError::UpstreamError(e.to_string()))?;
    Ok(models.data.into_iter().map(|m| m.id).collect())
}

/// Serialize the history into the request `messages` array. We serialize each
/// message from a borrow rather than cloning the whole slice first — histories
/// can carry multi-MB inline base64 images, so a per-call clone is pure waste
/// (the Ollama path avoids it the same way). Only tool-role messages are copied,
/// to drop their `name`: OpenAI-compatible tool results are matched by
/// `tool_call_id`, and `name` (kept internally for Ollama's native `tool_name`)
/// may be rejected by strict /v1 servers. Those messages are small.
fn messages_value(messages: &[ChatMessage]) -> Value {
    let items = messages
        .iter()
        .map(|message| {
            if message.role == "tool" && message.name.is_some() {
                let mut message = message.clone();
                message.name = None;
                json!(message)
            } else {
                json!(message)
            }
        })
        .collect();
    Value::Array(items)
}

fn apply_chat_template_thinking_hint(options: &mut Map<String, Value>) {
    let Some(enable_thinking) = requested_thinking(options) else {
        return;
    };

    let mut kwargs = options
        .remove("chat_template_kwargs")
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    kwargs
        .entry("enable_thinking")
        .or_insert(Value::Bool(enable_thinking));
    options.insert("chat_template_kwargs".into(), Value::Object(kwargs));
}

impl ChatBackend for OpenAICompatibleClient {
    async fn chat_once(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> Result<ChatMessage, AppError> {
        let request =
            Self::build_request(model, messages, tools, options, false, self.thinking_hint);
        let resp = self
            .authed_post(&self.chat_url())
            .json(&request)
            .send()
            .await
            .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }
        let response: Value = resp
            .json()
            .await
            .map_err(|e| AppError::UpstreamError(e.to_string()))?;

        if let Some(metrics) = &self.metrics {
            let usage = response.get("usage");
            let count = |key: &str| usage.and_then(|u| u.get(key)).and_then(Value::as_u64);
            metrics.record_usage(
                model,
                count("prompt_tokens"),
                count("completion_tokens"),
                None,
                None,
            );
        }

        response
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first())
            .and_then(|choice| choice.get("message"))
            .map(chat_message_from_openai)
            .transpose()?
            .ok_or_else(|| AppError::UpstreamError("missing chat completion message".into()))
    }

    async fn chat_stream(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> Result<DeltaStream, AppError> {
        let mut request =
            Self::build_request(model, messages, &[], options, true, self.thinking_hint);
        let mut resp = self
            .authed_post(&self.chat_url())
            .json(&request)
            .send()
            .await
            .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;
        if is_stream_options_rejection(resp.status()) {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            tracing::warn!(
                model = %model,
                %status,
                detail = %detail,
                "OpenAI-compatible upstream rejected streaming usage; retrying without stream_options"
            );
            if let Value::Object(body) = &mut request {
                body.remove("stream_options");
            }
            resp = self
                .authed_post(&self.chat_url())
                .json(&request)
                .send()
                .await
                .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;
        }
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }
        Ok(Box::pin(sse_bytes_to_deltas(
            resp.bytes_stream(),
            self.metrics
                .clone()
                .map(|metrics| (metrics, model.to_string())),
        )))
    }

    async fn chat_stream_tools(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> Result<Option<ToolDeltaStream>, AppError> {
        let mut request =
            Self::build_request(model, messages, tools, options, true, self.thinking_hint);
        let mut resp = self
            .authed_post(&self.chat_url())
            .json(&request)
            .send()
            .await
            .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;
        if is_stream_options_rejection(resp.status()) {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            tracing::warn!(
                model = %model,
                %status,
                detail = %detail,
                "OpenAI-compatible upstream rejected streaming usage; retrying without stream_options"
            );
            if let Value::Object(body) = &mut request {
                body.remove("stream_options");
            }
            resp = self
                .authed_post(&self.chat_url())
                .json(&request)
                .send()
                .await
                .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;
        }
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }
        Ok(Some(Box::pin(sse_bytes_to_tool_deltas(
            resp.bytes_stream(),
            None,
        ))))
    }
}

fn is_stream_options_rejection(status: reqwest::StatusCode) -> bool {
    matches!(
        status,
        reqwest::StatusCode::BAD_REQUEST
            | reqwest::StatusCode::UNPROCESSABLE_ENTITY
            | reqwest::StatusCode::NOT_IMPLEMENTED
    )
}

/// Turn the raw byte stream of an OpenAI `text/event-stream` response into
/// `StreamDelta`s, buffering partial lines across chunk boundaries. We only care
/// about `data:` lines; the `data: [DONE]` sentinel ends the stream, and blank
/// separators / comments (`:`) / other SSE fields (`event:`, `id:`) are ignored.
fn sse_bytes_to_deltas<S>(
    mut bytes: S,
    metrics: Option<(Arc<crate::metrics::Metrics>, String)>,
) -> impl Stream<Item = Result<StreamDelta, AppError>>
where
    S: Stream<Item = reqwest::Result<Bytes>> + Unpin,
{
    try_stream! {
        let mut buf = BytesMut::new();
        let mut think_tags = ThinkTagNormalizer::default();
        let started_at = Instant::now();
        let mut recorded_usage = false;
        let mut pending_done_reason: Option<String> = None;
        'read: while let Some(next) = bytes.next().await {
            let chunk = next.map_err(|e| AppError::UpstreamError(e.to_string()))?;
            buf.extend_from_slice(&chunk);

            while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line = buf.split_to(pos + 1);
                let Some(payload) = sse_data_payload(line.as_ref()) else {
                    continue;
                };
                if payload == b"[DONE]" {
                    if metrics.is_some() {
                        yield StreamDelta::new("", "", true, pending_done_reason.take());
                    }
                    break 'read;
                }
                let value: Value = serde_json::from_slice(payload)
                    .map_err(|e| AppError::UpstreamError(format!("bad SSE data line: {e}")))?;
                if record_stream_usage(&metrics, &value, started_at, &mut recorded_usage) {
                    continue;
                }
                let mut delta = delta_from_openai_chunk(&value);
                if metrics.is_some() && delta.done {
                    pending_done_reason = delta.done_reason.clone();
                    delta.done = false;
                }
                yield think_tags.normalize(delta);
            }
        }

        // Flush a final `data:` line that arrived without its terminating newline
        // (a server that closes the connection right after the last chunk, with no
        // `[DONE]` sentinel). The inner loop only splits on `\n`, so without this
        // the last delta — which carries `finish_reason` — would be lost. Lenient
        // like the NDJSON path: a truncated tail is dropped, not surfaced as error.
        if let Some(payload) = sse_data_payload(buf.as_ref()) {
            if payload != b"[DONE]" {
                if let Ok(value) = serde_json::from_slice::<Value>(payload) {
                    if record_stream_usage(&metrics, &value, started_at, &mut recorded_usage) {
                        return;
                    }
                    yield think_tags.normalize(delta_from_openai_chunk(&value));
                }
            }
        }
    }
}

fn sse_bytes_to_tool_deltas<S>(
    mut bytes: S,
    metrics: Option<(Arc<crate::metrics::Metrics>, String)>,
) -> impl Stream<Item = Result<ToolStreamDelta, AppError>>
where
    S: Stream<Item = reqwest::Result<Bytes>> + Unpin,
{
    try_stream! {
        let mut buf = BytesMut::new();
        let mut think_tags = ThinkTagNormalizer::default();
        let mut tool_calls = ToolCallAccumulator::default();
        let started_at = Instant::now();
        let mut recorded_usage = false;
        let mut pending_done_reason: Option<String> = None;
        'read: while let Some(next) = bytes.next().await {
            let chunk = next.map_err(|e| AppError::UpstreamError(e.to_string()))?;
            buf.extend_from_slice(&chunk);

            while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line = buf.split_to(pos + 1);
                let Some(payload) = sse_data_payload(line.as_ref()) else {
                    continue;
                };
                if payload == b"[DONE]" {
                    if metrics.is_some() {
                        yield ToolStreamDelta::new("", "", None, true, pending_done_reason.take());
                    }
                    break 'read;
                }
                let value: Value = serde_json::from_slice(payload)
                    .map_err(|e| AppError::UpstreamError(format!("bad SSE data line: {e}")))?;
                if record_stream_usage(&metrics, &value, started_at, &mut recorded_usage) {
                    continue;
                }
                tool_calls.absorb_chunk(&value);
                let mut delta = delta_from_openai_chunk(&value);
                if metrics.is_some() && delta.done {
                    pending_done_reason = delta.done_reason.clone();
                    delta.done = false;
                }
                let normalized = think_tags.normalize(delta);
                if !normalized.content.is_empty() || !normalized.reasoning.is_empty() {
                    yield ToolStreamDelta::new(
                        normalized.content,
                        normalized.reasoning,
                        None,
                        false,
                        None,
                    );
                }
                if normalized.done {
                    let calls = tool_calls.finish()?;
                    yield ToolStreamDelta::new(
                        "",
                        "",
                        calls,
                        true,
                        normalized.done_reason,
                    );
                    break 'read;
                }
            }
        }

        if let Some(payload) = sse_data_payload(buf.as_ref()) {
            if payload != b"[DONE]" {
                if let Ok(value) = serde_json::from_slice::<Value>(payload) {
                    if record_stream_usage(&metrics, &value, started_at, &mut recorded_usage) {
                        return;
                    }
                    tool_calls.absorb_chunk(&value);
                    let normalized = think_tags.normalize(delta_from_openai_chunk(&value));
                    if !normalized.content.is_empty() || !normalized.reasoning.is_empty() {
                        yield ToolStreamDelta::new(
                            normalized.content,
                            normalized.reasoning,
                            None,
                            false,
                            None,
                        );
                    }
                    if normalized.done {
                        let calls = tool_calls.finish()?;
                        yield ToolStreamDelta::new("", "", calls, true, normalized.done_reason);
                    }
                }
            }
        }
    }
}

fn record_stream_usage(
    metrics: &Option<(Arc<crate::metrics::Metrics>, String)>,
    value: &Value,
    started_at: Instant,
    recorded: &mut bool,
) -> bool {
    let Some(usage) = value.get("usage") else {
        return false;
    };
    let count = |key: &str| usage.get(key).and_then(Value::as_u64);
    let prompt_tokens = count("prompt_tokens");
    let completion_tokens = count("completion_tokens");
    if *recorded || (prompt_tokens.is_none() && completion_tokens.is_none()) {
        return true;
    }
    if let Some((metrics, model)) = metrics {
        let eval_duration_ns = completion_tokens
            .filter(|tokens| *tokens > 0)
            .map(|_| started_at.elapsed().as_nanos().min(u64::MAX as u128) as u64);
        metrics.record_usage(
            model,
            prompt_tokens,
            completion_tokens,
            eval_duration_ns,
            None,
        );
    }
    *recorded = true;
    true
}

/// The payload of an SSE `data:` line (trimmed), or `None` for a blank
/// separator, a `:` comment, or any non-`data` field line.
fn sse_data_payload(line: &[u8]) -> Option<&[u8]> {
    let line = line.trim_ascii();
    if line.is_empty() || line.starts_with(b":") {
        return None;
    }
    line.strip_prefix(b"data:").map(<[u8]>::trim_ascii)
}

#[derive(Default)]
struct ToolCallAccumulator {
    calls: BTreeMap<u32, PartialToolCall>,
}

#[derive(Default)]
struct PartialToolCall {
    id: Option<String>,
    kind: Option<String>,
    name: String,
    arguments: String,
}

impl ToolCallAccumulator {
    fn absorb_chunk(&mut self, value: &Value) {
        let Some(chunks) = value
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first())
            .and_then(|choice| choice.get("delta"))
            .and_then(|delta| delta.get("tool_calls"))
            .and_then(Value::as_array)
        else {
            return;
        };

        for chunk in chunks {
            let index = chunk
                .get("index")
                .and_then(Value::as_u64)
                .and_then(|n| u32::try_from(n).ok())
                .unwrap_or(0);
            let call = self.calls.entry(index).or_default();
            if let Some(id) = chunk.get("id").and_then(Value::as_str) {
                if !id.is_empty() {
                    call.id = Some(id.to_string());
                }
            }
            if let Some(kind) = chunk.get("type").and_then(Value::as_str) {
                if !kind.is_empty() {
                    call.kind = Some(kind.to_string());
                }
            }
            if let Some(function) = chunk.get("function").and_then(Value::as_object) {
                if let Some(name) = function.get("name").and_then(Value::as_str) {
                    call.name.push_str(name);
                }
                if let Some(arguments) = function.get("arguments").and_then(Value::as_str) {
                    call.arguments.push_str(arguments);
                }
            }
        }
    }

    fn finish(&self) -> Result<Option<Vec<ToolCall>>, AppError> {
        if self.calls.is_empty() {
            return Ok(None);
        }
        self.calls
            .values()
            .map(|call| {
                if call.name.trim().is_empty() {
                    return Err(AppError::UpstreamError(
                        "streamed tool call missing function name".into(),
                    ));
                }
                Ok(ToolCall {
                    id: call.id.clone(),
                    kind: call.kind.clone().unwrap_or_else(|| "function".into()),
                    function: FunctionCall {
                        name: call.name.clone(),
                        arguments: RawArguments::Str(if call.arguments.trim().is_empty() {
                            "{}".into()
                        } else {
                            call.arguments.clone()
                        }),
                    },
                })
            })
            .collect::<Result<Vec<_>, _>>()
            .map(Some)
    }
}

fn delta_from_openai_chunk(chunk: &Value) -> StreamDelta {
    let choice = chunk
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first());
    let delta = choice.and_then(|choice| choice.get("delta"));
    let content = delta
        .and_then(|delta| delta.get("content"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let reasoning = delta.and_then(reasoning_from_delta).unwrap_or_default();
    // Treat only a non-empty `finish_reason` as terminal: some compat servers
    // send `"finish_reason":""` (rather than null) on intermediate chunks, and an
    // empty string must not end the stream early.
    let done_reason = choice
        .and_then(|choice| choice.get("finish_reason"))
        .and_then(Value::as_str)
        .filter(|reason| !reason.is_empty())
        .map(ToString::to_string);
    StreamDelta::new(content, reasoning, done_reason.is_some(), done_reason)
}

fn reasoning_from_delta(delta: &Value) -> Option<&str> {
    delta
        .get("reasoning")
        .or_else(|| delta.get("reasoning_content"))
        .or_else(|| delta.get("thinking"))
        .and_then(Value::as_str)
}

#[derive(Default)]
struct ThinkTagNormalizer {
    pending: String,
    in_reasoning: bool,
}

impl ThinkTagNormalizer {
    fn normalize(&mut self, mut delta: StreamDelta) -> StreamDelta {
        // Scan content for inline <think> tags. Skip the scan only when the
        // upstream is already separating reasoning natively AND we are not
        // mid-tag AND nothing is pending: once a tag is open we must keep
        // scanning to find its close, even if a later chunk also carries a
        // native reasoning field — otherwise the </think> leaks into visible
        // content and `in_reasoning` stays stuck. And a held-back partial-tag
        // remainder must be resolved through the scan too, or it would only
        // flush at `done` — after this chunk's content, reordering the output.
        if !delta.content.is_empty()
            && (self.in_reasoning || !self.pending.is_empty() || delta.reasoning.is_empty())
        {
            let (content, reasoning) = self.process_content(&delta.content);
            delta.content = content;
            if delta.reasoning.is_empty() {
                delta.reasoning = reasoning;
            } else {
                delta.reasoning.push_str(&reasoning);
            }
        }
        if delta.done {
            let flushed = self.flush();
            if self.in_reasoning {
                delta.reasoning.push_str(&flushed);
            } else {
                delta.content.push_str(&flushed);
            }
            self.in_reasoning = false;
        }
        delta
    }

    fn process_content(&mut self, content: &str) -> (String, String) {
        self.pending.push_str(content);
        let mut visible = String::new();
        let mut reasoning = String::new();

        loop {
            if self.in_reasoning {
                if let Some(pos) = self.pending.find("</think>") {
                    reasoning.push_str(&self.pending[..pos]);
                    self.pending.drain(..pos + "</think>".len());
                    self.in_reasoning = false;
                } else {
                    let split = stable_prefix_len(&self.pending, "</think>");
                    reasoning.push_str(&self.pending[..split]);
                    self.pending.drain(..split);
                    break;
                }
            } else if let Some(pos) = self.pending.find("<think>") {
                visible.push_str(&self.pending[..pos]);
                self.pending.drain(..pos + "<think>".len());
                self.in_reasoning = true;
            } else {
                let split = stable_prefix_len(&self.pending, "<think>");
                visible.push_str(&self.pending[..split]);
                self.pending.drain(..split);
                break;
            }
        }

        (visible, reasoning)
    }

    fn flush(&mut self) -> String {
        std::mem::take(&mut self.pending)
    }
}

fn stable_prefix_len(s: &str, tag: &str) -> usize {
    let max_suffix = s.len().min(tag.len().saturating_sub(1));
    for len in (1..=max_suffix).rev() {
        let start = s.len() - len;
        if s.is_char_boundary(start) && tag.starts_with(&s[start..]) {
            return start;
        }
    }
    s.len()
}

fn chat_message_from_openai(value: &Value) -> Result<ChatMessage, AppError> {
    let role = value
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or("assistant")
        .to_string();
    let content = match value.get("content") {
        Some(Value::String(s)) => Some(MessageContent::Text(s.clone())),
        Some(Value::Null) | None => None,
        Some(other) => Some(MessageContent::Text(other.to_string())),
    };
    let tool_calls = value
        .get("tool_calls")
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|e| AppError::UpstreamError(format!("bad tool_calls: {e}")))?;

    Ok(ChatMessage {
        role,
        content,
        tool_calls,
        tool_call_id: None,
        name: None,
    })
}

pub fn openai_api_base(base: &Url) -> String {
    let trimmed = base.as_str().trim_end_matches('/');
    if base.path().trim_end_matches('/').ends_with("/v1") {
        trimmed.to_string()
    } else {
        format!("{trimmed}/v1")
    }
}

#[derive(Debug, Deserialize)]
struct ModelsResponse {
    data: Vec<ModelEntry>,
}

#[derive(Debug, Deserialize)]
struct ModelEntry {
    id: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn openai_api_base_adds_v1_for_root_urls() {
        let base = Url::parse("https://api.example.test").unwrap();
        assert_eq!(openai_api_base(&base), "https://api.example.test/v1");
    }

    #[test]
    fn openai_api_base_preserves_existing_v1_path() {
        let base = Url::parse("https://api.example.test/custom/v1/").unwrap();
        assert_eq!(openai_api_base(&base), "https://api.example.test/custom/v1");
    }

    #[test]
    fn sse_data_payload_extracts_and_ignores() {
        // A data line, with and without the optional space after the colon.
        assert_eq!(
            sse_data_payload(b"data: {\"a\":1}\n"),
            Some(&b"{\"a\":1}"[..])
        );
        assert_eq!(
            sse_data_payload(b"data:{\"a\":1}\n"),
            Some(&b"{\"a\":1}"[..])
        );
        // The terminating sentinel is surfaced verbatim for the caller to detect.
        assert_eq!(sse_data_payload(b"data: [DONE]\n"), Some(&b"[DONE]"[..]));
        // Blank separators, comments, and non-`data` fields are skipped.
        assert_eq!(sse_data_payload(b"\n"), None);
        assert_eq!(sse_data_payload(b": keep-alive comment\n"), None);
        assert_eq!(sse_data_payload(b"event: message\n"), None);
        assert_eq!(sse_data_payload(b"id: 42\n"), None);
    }

    #[tokio::test]
    async fn sse_stream_buffers_lines_split_across_chunks() {
        use bytes::Bytes;
        use futures_util::stream;

        // A single SSE data line deliberately split mid-JSON across two byte
        // chunks, then a finish chunk and the [DONE] sentinel arriving together.
        let chunks: Vec<reqwest::Result<Bytes>> = vec![
            Ok(Bytes::from_static(b"data: {\"choices\":[{\"delta\":{\"content\":\"He")),
            Ok(Bytes::from_static(
                b"llo\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
            )),
        ];
        let deltas: Vec<StreamDelta> = sse_bytes_to_deltas(stream::iter(chunks), None)
            .map(|r| r.unwrap())
            .collect()
            .await;

        // [DONE] yields nothing, so exactly two deltas: the reassembled content
        // and the terminal finish.
        assert_eq!(deltas.len(), 2);
        assert_eq!(deltas[0].content, "Hello");
        assert!(!deltas[0].done);
        assert!(deltas[1].done);
        assert_eq!(deltas[1].done_reason.as_deref(), Some("stop"));
    }

    #[tokio::test]
    async fn sse_stream_surfaces_malformed_data_line() {
        use bytes::Bytes;
        use futures_util::stream;

        let chunks: Vec<reqwest::Result<Bytes>> =
            vec![Ok(Bytes::from_static(b"data: {not json}\n\n"))];
        let mut got = Box::pin(sse_bytes_to_deltas(stream::iter(chunks), None));
        let first = got.next().await.expect("one item");
        assert!(matches!(first, Err(AppError::UpstreamError(_))));
    }

    #[tokio::test]
    async fn sse_stream_usage_records_tokens_and_throughput() {
        use bytes::Bytes;
        use futures_util::stream;

        let metrics = crate::metrics::Metrics::without_store();
        let chunks: Vec<reqwest::Result<Bytes>> = vec![Ok(Bytes::from_static(
            b"data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n\
              data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n\
              data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"total_tokens\":10}}\n\n\
              data: [DONE]\n\n",
        ))];
        let deltas: Vec<StreamDelta> =
            sse_bytes_to_deltas(stream::iter(chunks), Some((metrics.clone(), "m".into())))
                .map(|r| r.unwrap())
                .collect()
                .await;

        assert_eq!(deltas.len(), 3, "usage-only chunks are not relayed");
        assert!(deltas[2].done);
        let stats = metrics.model("m");
        assert_eq!(stats.prompt_tokens.get(), 7);
        assert_eq!(stats.completion_tokens.get(), 3);
        assert_eq!(stats.tokens_per_sec.snapshot().count, 1);
    }

    #[test]
    fn parses_stream_delta() {
        let chunk = json!({
            "choices": [{
                "delta": { "content": "hi" },
                "finish_reason": null
            }]
        });
        let delta = delta_from_openai_chunk(&chunk);
        assert_eq!(delta.content, "hi");
        assert_eq!(delta.reasoning, "");
        assert!(!delta.done);

        let chunk = json!({
            "choices": [{
                "delta": { "reasoning_content": "plan" },
                "finish_reason": null
            }]
        });
        let delta = delta_from_openai_chunk(&chunk);
        assert_eq!(delta.reasoning, "plan");

        let finish = json!({
            "choices": [{
                "delta": {},
                "finish_reason": "stop"
            }]
        });
        let delta = delta_from_openai_chunk(&finish);
        assert!(delta.done);
        assert_eq!(delta.done_reason.as_deref(), Some("stop"));
    }

    #[test]
    fn think_tag_normalizer_moves_tagged_content_to_reasoning() {
        let mut normalizer = ThinkTagNormalizer::default();

        let first = normalizer.normalize(StreamDelta::content("<think>plan", false, None));
        let second = normalizer.normalize(StreamDelta::content("</think>answer", false, None));

        assert_eq!(first.content, "");
        assert_eq!(first.reasoning, "plan");
        assert_eq!(second.content, "answer");
        assert_eq!(second.reasoning, "");
    }

    #[test]
    fn think_tag_normalizer_handles_split_tags() {
        let mut normalizer = ThinkTagNormalizer::default();

        let first = normalizer.normalize(StreamDelta::content("<thi", false, None));
        let second = normalizer.normalize(StreamDelta::content("nk>plan</th", false, None));
        let third = normalizer.normalize(StreamDelta::content("ink>done", false, None));

        assert_eq!(first.content, "");
        assert_eq!(first.reasoning, "");
        assert_eq!(second.content, "");
        assert_eq!(second.reasoning, "plan");
        assert_eq!(third.content, "done");
        assert_eq!(third.reasoning, "");
    }

    #[test]
    fn think_tag_normalizer_handles_mixed_tagged_content() {
        let mut normalizer = ThinkTagNormalizer::default();

        let delta = normalizer.normalize(StreamDelta::content(
            "before <think>plan</think> after",
            false,
            None,
        ));

        assert_eq!(delta.content, "before  after");
        assert_eq!(delta.reasoning, "plan");
    }

    #[test]
    fn think_tag_normalizer_leaves_ordinary_content_untouched() {
        let mut normalizer = ThinkTagNormalizer::default();

        let delta = normalizer.normalize(StreamDelta::content("plain answer", false, None));

        assert_eq!(delta.content, "plain answer");
        assert_eq!(delta.reasoning, "");
    }

    #[test]
    fn think_tag_normalizer_flushes_unclosed_tag_as_reasoning_on_done() {
        let mut normalizer = ThinkTagNormalizer::default();

        let first = normalizer.normalize(StreamDelta::content("<think>plan", false, None));
        let done = normalizer.normalize(StreamDelta::content(
            " still planning",
            true,
            Some("stop".into()),
        ));

        assert_eq!(first.content, "");
        assert_eq!(first.reasoning, "plan");
        assert_eq!(done.content, "");
        assert_eq!(done.reasoning, " still planning");
        assert!(done.done);
    }

    #[test]
    fn build_request_preserves_disabled_reasoning_effort() {
        let mut options = Map::new();
        options.insert("reasoning_effort".into(), Value::String("none".into()));
        options.insert("temperature".into(), json!(0.2));

        let body = OpenAICompatibleClient::build_request("m", &[], &[], &options, true, true);

        assert_eq!(body["reasoning_effort"], "none");
        assert_eq!(body["chat_template_kwargs"]["enable_thinking"], false);
        assert_eq!(body["temperature"], json!(0.2));
    }

    #[test]
    fn build_request_preserves_enabled_reasoning_effort() {
        let mut options = Map::new();
        options.insert("reasoning_effort".into(), Value::String("medium".into()));

        let body = OpenAICompatibleClient::build_request("m", &[], &[], &options, true, true);

        assert_eq!(body["reasoning_effort"], "medium");
        assert_eq!(body["chat_template_kwargs"]["enable_thinking"], true);
    }

    #[test]
    fn build_request_maps_nested_disabled_reasoning_effort() {
        let mut options = Map::new();
        options.insert("reasoning".into(), json!({ "effort": "none" }));

        let body = OpenAICompatibleClient::build_request("m", &[], &[], &options, true, true);

        assert_eq!(body["reasoning"]["effort"], "none");
        assert_eq!(body["chat_template_kwargs"]["enable_thinking"], false);
    }

    #[test]
    fn build_request_preserves_existing_chat_template_kwargs() {
        let mut options = Map::new();
        options.insert("reasoning_effort".into(), Value::String("none".into()));
        options.insert(
            "chat_template_kwargs".into(),
            json!({ "foo": "bar", "enable_thinking": true }),
        );

        let body = OpenAICompatibleClient::build_request("m", &[], &[], &options, true, true);

        assert_eq!(body["chat_template_kwargs"]["foo"], "bar");
        assert_eq!(body["chat_template_kwargs"]["enable_thinking"], true);
    }

    #[test]
    fn build_request_forwards_tool_choice_only_when_tools_are_offered() {
        let mut options = Map::new();
        options.insert(
            "tool_choice".into(),
            json!({"type":"function","function":{"name":"time"}}),
        );
        let tools = vec![json!({"type":"function","function":{"name":"time"}})];
        let with_tools =
            OpenAICompatibleClient::build_request("m", &[], &tools, &options, false, true);
        assert_eq!(with_tools["tool_choice"]["function"]["name"], "time");

        let without_tools =
            OpenAICompatibleClient::build_request("m", &[], &[], &options, true, true);
        assert!(without_tools.get("tool_choice").is_none());
    }

    #[test]
    fn build_request_omits_tool_name_from_tool_results() {
        let messages = vec![ChatMessage::tool_result("call_1", "calculator", "2")];
        let body =
            OpenAICompatibleClient::build_request("m", &messages, &[], &Map::new(), false, true);
        let message = &body["messages"][0];

        assert_eq!(message["role"], "tool");
        assert_eq!(message["tool_call_id"], "call_1");
        assert!(message.get("name").is_none());
    }

    #[test]
    fn build_request_omits_thinking_hint_when_disabled() {
        let mut options = Map::new();
        options.insert("reasoning_effort".into(), Value::String("none".into()));

        let body = OpenAICompatibleClient::build_request("m", &[], &[], &options, true, false);

        // reasoning_effort still rides through, but the Qwen-style template hint is
        // not injected — for strict /v1 servers that reject unknown body fields.
        assert_eq!(body["reasoning_effort"], "none");
        assert!(body.get("chat_template_kwargs").is_none());
    }

    #[test]
    fn empty_finish_reason_is_not_terminal() {
        // Some compat servers send "finish_reason":"" on intermediate chunks.
        let chunk = json!({
            "choices": [{ "delta": { "content": "hi" }, "finish_reason": "" }]
        });
        let delta = delta_from_openai_chunk(&chunk);
        assert_eq!(delta.content, "hi");
        assert!(
            !delta.done,
            "an empty finish_reason must not end the stream"
        );
        assert_eq!(delta.done_reason, None);
    }

    #[tokio::test]
    async fn sse_stream_flushes_final_line_without_newline() {
        use bytes::Bytes;
        use futures_util::stream;

        // A server that closes after the final chunk with no trailing newline and
        // no [DONE] sentinel; the terminal delta must still be emitted.
        let chunks: Vec<reqwest::Result<Bytes>> = vec![Ok(Bytes::from_static(
            b"data: {\"choices\":[{\"delta\":{\"content\":\"bye\"},\"finish_reason\":\"stop\"}]}",
        ))];
        let deltas: Vec<StreamDelta> = sse_bytes_to_deltas(stream::iter(chunks), None)
            .map(|r| r.unwrap())
            .collect()
            .await;

        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0].content, "bye");
        assert!(deltas[0].done);
        assert_eq!(deltas[0].done_reason.as_deref(), Some("stop"));
    }

    #[test]
    fn think_tag_normalizer_keeps_order_when_native_reasoning_follows_partial_tag() {
        let mut normalizer = ThinkTagNormalizer::default();

        // A pure-content chunk ends in a possible tag prefix, held back as
        // pending. The next chunk carries BOTH native reasoning and content:
        // the scan must not be skipped, or the pending "<thi" would only flush
        // at done — after this chunk's content, reordering the output.
        let first = normalizer.normalize(StreamDelta::content("<thi", false, None));
        assert_eq!(first.content, "");
        assert_eq!(first.reasoning, "");

        let second = normalizer.normalize(StreamDelta::new("s is text", "native", false, None));
        assert_eq!(
            second.content, "<this is text",
            "pending prefix resolves in order with the chunk's content"
        );
        assert_eq!(second.reasoning, "native");

        let done = normalizer.normalize(StreamDelta::content("", true, Some("stop".into())));
        assert_eq!(done.content, "", "nothing left to flush at done");
        assert_eq!(done.reasoning, "");
    }

    #[test]
    fn think_tag_normalizer_recovers_when_native_reasoning_accompanies_close_tag() {
        let mut normalizer = ThinkTagNormalizer::default();

        // Tag opened in a pure-content chunk, then the close arrives on a chunk
        // that also carries a native reasoning field. The close must still be
        // consumed so it does not leak and the state machine recovers.
        let first = normalizer.normalize(StreamDelta::content("<think>plan", false, None));
        let second =
            normalizer.normalize(StreamDelta::new("</think>answer", "native", false, None));
        let third = normalizer.normalize(StreamDelta::content(" more", false, None));

        assert_eq!(first.reasoning, "plan");
        assert_eq!(second.content, "answer");
        assert_eq!(second.reasoning, "native");
        assert_eq!(third.content, " more", "must not be stuck in reasoning");
        assert_eq!(third.reasoning, "");
    }
}
