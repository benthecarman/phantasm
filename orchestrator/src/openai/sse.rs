//! Helpers for building the OpenAI-compatible SSE byte stream sent to the app.
//!
//! Each event is `data: {json}\n\n`; the stream is terminated by the literal
//! `data: [DONE]`. We model events as `axum::response::sse::Event` so the
//! framework handles framing, but the chunk *shape* is OpenAI's.

use std::time::{SystemTime, UNIX_EPOCH};

use axum::response::sse::Event;

use super::types::{ChatChunk, ChunkChoice, Delta, DeltaFunctionCall, DeltaToolCall, ToolCall};

/// A turn-scoped builder so every chunk shares one `id`/`model`/`created`.
#[derive(Clone)]
pub struct ChunkFactory {
    id: String,
    model: String,
    created: i64,
}

impl ChunkFactory {
    pub fn new(model: impl Into<String>) -> Self {
        ChunkFactory {
            id: format!("chatcmpl-{}", uuid::Uuid::new_v4().simple()),
            model: model.into(),
            created: now_secs(),
        }
    }

    fn base(
        &self,
        choices: Vec<ChunkChoice>,
        x_status: Option<String>,
        x_progress: Option<f64>,
    ) -> ChatChunk {
        ChatChunk {
            id: self.id.clone(),
            object: "chat.completion.chunk",
            created: self.created,
            model: self.model.clone(),
            choices,
            x_status,
            x_progress,
        }
    }

    /// A content token delta.
    pub fn token(&self, content: &str) -> Event {
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::content(content),
                finish_reason: None,
            }],
            None,
            None,
        );
        to_event(&chunk)
    }

    /// A model thinking/reasoning delta.
    pub fn reasoning(&self, reasoning: &str) -> Event {
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::reasoning(reasoning),
                finish_reason: None,
            }],
            None,
            None,
        );
        to_event(&chunk)
    }

    /// The opening chunk carrying `delta.role = "assistant"` (matches OpenAI).
    pub fn role_open(&self) -> Event {
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::role("assistant"),
                finish_reason: None,
            }],
            None,
            None,
        );
        to_event(&chunk)
    }

    /// A progress heartbeat with no content — only the additive `x_status` field.
    pub fn status(&self, status: &str) -> Event {
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::default(),
                finish_reason: None,
            }],
            Some(status.to_string()),
            None,
        );
        to_event(&chunk)
    }

    /// A determinate progress heartbeat with no content. The status text stays
    /// human-readable; `x_progress` gives native clients the normalized value.
    pub fn progress(&self, status: &str, progress: f64) -> Event {
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::default(),
                finish_reason: None,
            }],
            Some(status.to_string()),
            Some(progress.clamp(0.0, 1.0)),
        );
        to_event(&chunk)
    }

    /// A chunk handing app-hosted tool calls back to the app to execute
    /// (standard OpenAI `delta.tool_calls`). Followed by a `finish("tool_calls")`
    /// chunk and `[DONE]`.
    pub fn tool_calls(&self, calls: &[ToolCall]) -> Event {
        let deltas = calls
            .iter()
            .enumerate()
            .map(|(i, c)| DeltaToolCall {
                index: i as u32,
                id: Some(ensure_call_id(c)),
                kind: "function",
                function: DeltaFunctionCall {
                    name: c.function.name.clone(),
                    arguments: c.function.arguments.to_json_string(),
                },
            })
            .collect();
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::tool_calls(deltas),
                finish_reason: None,
            }],
            None,
            None,
        );
        to_event(&chunk)
    }

    /// The terminal chunk carrying `finish_reason`.
    pub fn finish(&self, reason: &str) -> Event {
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::default(),
                finish_reason: Some(reason.to_string()),
            }],
            None,
            None,
        );
        to_event(&chunk)
    }
}

/// The literal `[DONE]` sentinel that ends an OpenAI SSE stream.
pub fn done_event() -> Event {
    Event::default().data("[DONE]")
}

/// A tool call's id, minting one when the upstream omitted it. Shared by the
/// streaming (`ChunkFactory::tool_calls`) and non-streaming response paths so the
/// id the app echoes back as `tool_call_id` is generated the same way.
pub fn ensure_call_id(call: &ToolCall) -> String {
    call.id
        .clone()
        .unwrap_or_else(|| format!("call_{}", uuid::Uuid::new_v4().simple()))
}

fn to_event(chunk: &ChatChunk) -> Event {
    // Serialization of our own owned types cannot fail; fall back defensively.
    match serde_json::to_string(chunk) {
        Ok(json) => Event::default().data(json),
        Err(_) => Event::default().data("{}"),
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `Event` doesn't expose its data, so we reserialize the chunk struct to
    /// assert shape. This validates the OpenAI envelope + additive x_status.
    fn chunk_json(c: &ChatChunk) -> serde_json::Value {
        serde_json::to_value(c).unwrap()
    }

    #[test]
    fn token_chunk_has_openai_shape() {
        let f = ChunkFactory::new("llama3.1");
        let chunk = f.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::content("hi"),
                finish_reason: None,
            }],
            None,
            None,
        );
        let v = chunk_json(&chunk);
        assert_eq!(v["object"], "chat.completion.chunk");
        assert_eq!(v["choices"][0]["delta"]["content"], "hi");
        assert!(v.get("x_status").is_none(), "x_status omitted when absent");
        assert!(
            v.get("x_progress").is_none(),
            "x_progress omitted when absent"
        );
        assert!(v["id"].as_str().unwrap().starts_with("chatcmpl-"));
    }

    #[test]
    fn status_chunk_carries_x_status_and_empty_delta() {
        let f = ChunkFactory::new("llama3.1");
        let chunk = f.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::default(),
                finish_reason: None,
            }],
            Some("searching the web…".into()),
            None,
        );
        let v = chunk_json(&chunk);
        assert_eq!(v["x_status"], "searching the web…");
        assert!(v.get("x_progress").is_none());
        assert!(v["choices"][0]["delta"].as_object().unwrap().is_empty());
    }

    #[test]
    fn progress_chunk_carries_status_and_normalized_progress() {
        let f = ChunkFactory::new("llama3.1");
        let chunk = f.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::default(),
                finish_reason: None,
            }],
            Some("generating image… 42%".into()),
            Some(0.42),
        );
        let v = chunk_json(&chunk);
        assert_eq!(v["x_status"], "generating image… 42%");
        assert_eq!(v["x_progress"], 0.42);
        assert!(v["choices"][0]["delta"].as_object().unwrap().is_empty());
    }

    #[test]
    fn reasoning_chunk_carries_reasoning_delta() {
        let f = ChunkFactory::new("llama3.1");
        let chunk = f.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::reasoning("plan"),
                finish_reason: None,
            }],
            None,
            None,
        );
        let v = chunk_json(&chunk);
        assert_eq!(v["choices"][0]["delta"]["reasoning_content"], "plan");
    }

    #[test]
    fn tool_calls_chunk_serializes_openai_shape() {
        let f = ChunkFactory::new("m");
        let chunk = f.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::tool_calls(vec![DeltaToolCall {
                    index: 0,
                    id: Some("call_x".into()),
                    kind: "function",
                    function: DeltaFunctionCall {
                        name: "ask_user".into(),
                        arguments: "{\"a\":1}".into(),
                    },
                }]),
                finish_reason: None,
            }],
            None,
            None,
        );
        let v = chunk_json(&chunk);
        let tc = &v["choices"][0]["delta"]["tool_calls"][0];
        assert_eq!(tc["index"], 0);
        assert_eq!(tc["id"], "call_x");
        assert_eq!(tc["type"], "function");
        assert_eq!(tc["function"]["name"], "ask_user");
        assert_eq!(
            tc["function"]["arguments"], "{\"a\":1}",
            "arguments is a JSON-encoded string, not an object"
        );
    }

    #[test]
    fn ensure_call_id_mints_when_absent() {
        use super::super::types::{FunctionCall, RawArguments};
        let with_id = ToolCall {
            id: Some("call_keep".into()),
            kind: "function".into(),
            function: FunctionCall {
                name: "t".into(),
                arguments: RawArguments::Obj(serde_json::json!({})),
            },
        };
        assert_eq!(ensure_call_id(&with_id), "call_keep");
        let without = ToolCall {
            id: None,
            ..with_id
        };
        assert!(ensure_call_id(&without).starts_with("call_"));
    }

    #[test]
    fn finish_chunk_sets_reason() {
        let f = ChunkFactory::new("m");
        let chunk = f.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta::default(),
                finish_reason: Some("stop".into()),
            }],
            None,
            None,
        );
        let v = chunk_json(&chunk);
        assert_eq!(v["choices"][0]["finish_reason"], "stop");
    }
}
