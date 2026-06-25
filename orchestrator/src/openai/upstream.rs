//! OpenAI-compatible upstream chat client.
//!
//! This is used when startup probing finds `/v1/models` but not Ollama's
//! native `/api/tags`. The downstream app contract remains our own
//! OpenAI-compatible endpoint; this client is only for model-host traffic.

use async_openai::config::Config as AsyncOpenAIConfig;
use async_openai::Client;
use async_stream::try_stream;
use futures_util::{Stream, StreamExt};
use reqwest13::header::{HeaderMap, AUTHORIZATION};
use secrecy::{ExposeSecret, SecretString};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use url::Url;

use crate::error::AppError;
use crate::ollama::{ChatBackend, DeltaStream, StreamDelta};
use crate::openai::types::{ChatMessage, MessageContent};

#[derive(Clone)]
pub struct OpenAICompatibleClient {
    client: Client<OptionalAuthConfig>,
}

impl OpenAICompatibleClient {
    pub fn new(base: &Url, api_key: Option<&str>) -> Self {
        let config = OptionalAuthConfig::new(openai_api_base(base), api_key);
        OpenAICompatibleClient {
            client: Client::with_config(config),
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
        body.insert("model".into(), Value::String(model.to_string()));
        body.insert("messages".into(), json!(messages));
        body.insert("stream".into(), Value::Bool(stream));
        if !tools.is_empty() {
            body.insert("tools".into(), Value::Array(tools.to_vec()));
        }
        Value::Object(body)
    }
}

#[derive(Clone, Debug)]
struct OptionalAuthConfig {
    api_base: String,
    api_key: SecretString,
    has_api_key: bool,
}

impl OptionalAuthConfig {
    fn new(api_base: String, api_key: Option<&str>) -> Self {
        let api_key = api_key.map(str::trim).filter(|s| !s.is_empty());
        OptionalAuthConfig {
            api_base,
            api_key: SecretString::from(api_key.unwrap_or_default().to_string()),
            has_api_key: api_key.is_some(),
        }
    }
}

impl AsyncOpenAIConfig for OptionalAuthConfig {
    fn headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if self.has_api_key {
            headers.insert(
                AUTHORIZATION,
                format!("Bearer {}", self.api_key.expose_secret())
                    .parse()
                    .unwrap(),
            );
        }
        headers
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.api_base, path)
    }

    fn query(&self) -> Vec<(&str, &str)> {
        vec![]
    }

    fn api_base(&self) -> &str {
        &self.api_base
    }

    fn api_key(&self) -> &SecretString {
        &self.api_key
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
        let response: Value = self
            .client
            .chat()
            .create_byot(request)
            .await
            .map_err(map_openai_error)?;

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
        let stream = self
            .client
            .chat()
            .create_stream_byot(request)
            .await
            .map_err(map_openai_error)?;
        Ok(Box::pin(openai_chunks_to_deltas(stream)))
    }
}

fn openai_chunks_to_deltas<S>(mut stream: S) -> impl Stream<Item = Result<StreamDelta, AppError>>
where
    S: Stream<Item = Result<Value, async_openai::error::OpenAIError>> + Unpin,
{
    try_stream! {
        while let Some(next) = stream.next().await {
            let chunk = next.map_err(map_openai_error)?;
            yield delta_from_openai_chunk(&chunk);
        }
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

fn map_openai_error(error: async_openai::error::OpenAIError) -> AppError {
    AppError::OllamaError(error.to_string())
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
}
