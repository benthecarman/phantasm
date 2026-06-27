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
use url::Url;

use crate::error::AppError;
use crate::ollama::{ChatBackend, DeltaStream, StreamDelta};
use crate::openai::types::{ChatMessage, MessageContent};

const REASONING_EFFORT_NONE: &str = "none";

#[derive(Clone)]
pub struct OpenAICompatibleClient {
    http: reqwest::Client,
    /// Already normalized to end in `/v1` (no trailing slash) by [`openai_api_base`].
    api_base: String,
    /// Bearer token sent on every request, when the deployment requires one.
    api_key: Option<SecretString>,
}

impl OpenAICompatibleClient {
    pub fn new(http: reqwest::Client, base: &Url, api_key: Option<&str>) -> Self {
        let api_key = api_key
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| SecretString::from(s.to_string()));
        OpenAICompatibleClient {
            http,
            api_base: openai_api_base(base),
            api_key,
        }
    }

    /// A POST builder carrying the bearer token when one is configured.
    fn authed_post(&self, url: &str) -> reqwest::RequestBuilder {
        let req = self.http.post(url);
        match &self.api_key {
            Some(key) => req.bearer_auth(key.expose_secret()),
            None => req,
        }
    }

    pub async fn list_models(
        http: &reqwest::Client,
        base: &Url,
        api_key: Option<&str>,
    ) -> Result<Vec<String>, AppError> {
        let url = Url::parse(&format!(
            "{}/models",
            openai_api_base(base).trim_end_matches('/')
        ))
        .map_err(|e| AppError::Internal(format!("bad OpenAI upstream URL: {e}")))?;
        let mut req = http.get(url);
        if let Some(api_key) = api_key.filter(|s| !s.trim().is_empty()) {
            req = req.bearer_auth(api_key);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| AppError::OllamaUnreachable(e.to_string()))?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::OllamaError(format!("{status}: {detail}")));
        }
        let models: ModelsResponse = resp
            .json()
            .await
            .map_err(|e| AppError::OllamaError(e.to_string()))?;
        Ok(models.data.into_iter().map(|m| m.id).collect())
    }

    fn build_request(
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
        stream: bool,
    ) -> Value {
        let mut body = options.clone();
        remove_noop_reasoning_suppression(&mut body);
        body.insert("model".into(), Value::String(model.to_string()));
        body.insert("messages".into(), json!(messages));
        body.insert("stream".into(), Value::Bool(stream));
        if !tools.is_empty() {
            body.insert("tools".into(), Value::Array(tools.to_vec()));
        }
        Value::Object(body)
    }

    fn chat_url(&self) -> String {
        format!("{}/chat/completions", self.api_base)
    }
}

fn remove_noop_reasoning_suppression(options: &mut Map<String, Value>) {
    if options
        .get("reasoning_effort")
        .and_then(Value::as_str)
        .is_some_and(|effort| effort.eq_ignore_ascii_case(REASONING_EFFORT_NONE))
    {
        options.remove("reasoning_effort");
    }

    let nested_none = options
        .get("reasoning")
        .and_then(Value::as_object)
        .and_then(|reasoning| reasoning.get("effort"))
        .and_then(Value::as_str)
        .is_some_and(|effort| effort.eq_ignore_ascii_case(REASONING_EFFORT_NONE));
    if nested_none {
        options.remove("reasoning");
    }
}

impl ChatBackend for OpenAICompatibleClient {
    async fn chat_once(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> Result<ChatMessage, AppError> {
        let request = Self::build_request(model, messages, tools, options, false);
        let resp = self
            .authed_post(&self.chat_url())
            .json(&request)
            .send()
            .await
            .map_err(|e| AppError::OllamaUnreachable(e.to_string()))?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::OllamaError(format!("{status}: {detail}")));
        }
        let response: Value = resp
            .json()
            .await
            .map_err(|e| AppError::OllamaError(e.to_string()))?;

        response
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first())
            .and_then(|choice| choice.get("message"))
            .map(chat_message_from_openai)
            .transpose()?
            .ok_or_else(|| AppError::OllamaError("missing chat completion message".into()))
    }

    async fn chat_stream(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> Result<DeltaStream, AppError> {
        let request = Self::build_request(model, messages, &[], options, true);
        let resp = self
            .authed_post(&self.chat_url())
            .json(&request)
            .send()
            .await
            .map_err(|e| AppError::OllamaUnreachable(e.to_string()))?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::OllamaError(format!("{status}: {detail}")));
        }
        Ok(Box::pin(sse_bytes_to_deltas(resp.bytes_stream())))
    }
}

/// Turn the raw byte stream of an OpenAI `text/event-stream` response into
/// `StreamDelta`s, buffering partial lines across chunk boundaries. We only care
/// about `data:` lines; the `data: [DONE]` sentinel ends the stream, and blank
/// separators / comments (`:`) / other SSE fields (`event:`, `id:`) are ignored.
fn sse_bytes_to_deltas<S>(mut bytes: S) -> impl Stream<Item = Result<StreamDelta, AppError>>
where
    S: Stream<Item = reqwest::Result<Bytes>> + Unpin,
{
    try_stream! {
        let mut buf = BytesMut::new();
        'read: while let Some(next) = bytes.next().await {
            let chunk = next.map_err(|e| AppError::OllamaError(e.to_string()))?;
            buf.extend_from_slice(&chunk);

            while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line = buf.split_to(pos + 1);
                let Some(payload) = sse_data_payload(line.as_ref()) else {
                    continue;
                };
                if payload == b"[DONE]" {
                    break 'read;
                }
                let value: Value = serde_json::from_slice(payload)
                    .map_err(|e| AppError::OllamaError(format!("bad SSE data line: {e}")))?;
                yield delta_from_openai_chunk(&value);
            }
        }
    }
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
    let done_reason = choice
        .and_then(|choice| choice.get("finish_reason"))
        .and_then(Value::as_str)
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
        .map_err(|e| AppError::OllamaError(format!("bad tool_calls: {e}")))?;

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
        let deltas: Vec<StreamDelta> = sse_bytes_to_deltas(stream::iter(chunks))
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
        let mut got = Box::pin(sse_bytes_to_deltas(stream::iter(chunks)));
        let first = got.next().await.expect("one item");
        assert!(matches!(first, Err(AppError::OllamaError(_))));
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
    fn build_request_drops_noop_reasoning_suppression() {
        let mut options = Map::new();
        options.insert("reasoning_effort".into(), Value::String("none".into()));
        options.insert("temperature".into(), json!(0.2));

        let body = OpenAICompatibleClient::build_request("m", &[], &[], &options, true);

        assert!(body.get("reasoning_effort").is_none());
        assert_eq!(body["temperature"], json!(0.2));
    }

    #[test]
    fn build_request_preserves_enabled_reasoning_effort() {
        let mut options = Map::new();
        options.insert("reasoning_effort".into(), Value::String("medium".into()));

        let body = OpenAICompatibleClient::build_request("m", &[], &[], &options, true);

        assert_eq!(body["reasoning_effort"], "medium");
    }
}
