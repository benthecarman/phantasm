//! Helpers for building the OpenAI-compatible SSE byte stream sent to the app.
//!
//! Each event is `data: {json}\n\n`; the stream is terminated by the literal
//! `data: [DONE]`. We model events as `axum::response::sse::Event` so the
//! framework handles framing, but the chunk *shape* is OpenAI's.

use std::time::{SystemTime, UNIX_EPOCH};

use axum::response::sse::Event;

use super::types::{ChatChunk, ChunkChoice, Delta};

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

    fn base(&self, choices: Vec<ChunkChoice>, x_status: Option<String>) -> ChatChunk {
        ChatChunk {
            id: self.id.clone(),
            object: "chat.completion.chunk",
            created: self.created,
            model: self.model.clone(),
            choices,
            x_status,
        }
    }

    /// A content token delta.
    pub fn token(&self, content: &str) -> Event {
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta {
                    role: None,
                    content: Some(content.to_string()),
                },
                finish_reason: None,
            }],
            None,
        );
        to_event(&chunk)
    }

    /// The opening chunk carrying `delta.role = "assistant"` (matches OpenAI).
    pub fn role_open(&self) -> Event {
        let chunk = self.base(
            vec![ChunkChoice {
                index: 0,
                delta: Delta {
                    role: Some("assistant".into()),
                    content: None,
                },
                finish_reason: None,
            }],
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
        );
        to_event(&chunk)
    }
}

/// The literal `[DONE]` sentinel that ends an OpenAI SSE stream.
pub fn done_event() -> Event {
    Event::default().data("[DONE]")
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
                delta: Delta {
                    role: None,
                    content: Some("hi".into()),
                },
                finish_reason: None,
            }],
            None,
        );
        let v = chunk_json(&chunk);
        assert_eq!(v["object"], "chat.completion.chunk");
        assert_eq!(v["choices"][0]["delta"]["content"], "hi");
        assert!(v.get("x_status").is_none(), "x_status omitted when absent");
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
        );
        let v = chunk_json(&chunk);
        assert_eq!(v["x_status"], "searching the web…");
        assert!(v["choices"][0]["delta"].as_object().unwrap().is_empty());
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
        );
        let v = chunk_json(&chunk);
        assert_eq!(v["choices"][0]["finish_reason"], "stop");
    }
}
