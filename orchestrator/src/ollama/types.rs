//! Ollama *native* `/api/chat` wire types.
//!
//! We use the native API rather than Ollama's OpenAI-compat endpoint because
//! the latter silently drops `tool_calls` when `stream:true`. The native API
//! has reliable streaming + tool calling. Conversions to/from our OpenAI
//! `ChatMessage` live here so the rest of the codebase speaks one dialect.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::openai::types::{ChatMessage, FunctionCall, RawArguments, ToolCall};

#[derive(Debug, Serialize)]
pub struct OllamaChatRequest {
    pub model: String,
    pub messages: Vec<OllamaMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<Value>>,
    pub stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub think: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<Value>,
    /// Keep the model resident across turns so KV cache is reused (NFR-O8).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keep_alive: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct OllamaMessage {
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<OllamaToolCall>>,
    /// Ollama labels tool results by tool *name* rather than call id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OllamaToolCall {
    pub function: OllamaFunctionCall,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OllamaFunctionCall {
    pub name: String,
    /// Native API uses a JSON object (not a stringified blob) for arguments.
    #[serde(default)]
    pub arguments: Value,
}

/// One NDJSON line from a streaming (or the single object from a non-streaming)
/// `/api/chat` response.
#[derive(Debug, Deserialize)]
pub struct OllamaChatChunk {
    #[serde(default)]
    pub message: Option<OllamaMessage>,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub done_reason: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TagsResponse {
    #[serde(default)]
    pub models: Vec<TagModel>,
}

#[derive(Debug, Deserialize)]
pub struct TagModel {
    pub name: String,
}

// ---- conversions ----

impl OllamaMessage {
    /// Convert our OpenAI-dialect message to the native shape.
    pub fn from_openai(m: &ChatMessage) -> Self {
        OllamaMessage {
            role: m.role.clone(),
            content: m.content.clone(),
            tool_calls: m.tool_calls.as_ref().map(|calls| {
                calls
                    .iter()
                    .map(|c| OllamaToolCall {
                        function: OllamaFunctionCall {
                            name: c.function.name.clone(),
                            arguments: match &c.function.arguments {
                                RawArguments::Obj(v) => v.clone(),
                                RawArguments::Str(s) => {
                                    serde_json::from_str(s).unwrap_or(Value::String(s.clone()))
                                }
                            },
                        },
                    })
                    .collect()
            }),
            // For tool-role messages, surface the function name to Ollama.
            tool_name: if m.role == "tool" {
                m.name.clone()
            } else {
                None
            },
        }
    }

    /// Convert a native assistant message back to our OpenAI dialect, minting a
    /// synthetic call id (the native API doesn't supply one).
    pub fn into_openai(self) -> ChatMessage {
        let tool_calls = self.tool_calls.map(|calls| {
            calls
                .into_iter()
                .map(|c| ToolCall {
                    id: Some(format!("call_{}", uuid::Uuid::new_v4().simple())),
                    kind: "function".into(),
                    function: FunctionCall {
                        name: c.function.name,
                        arguments: RawArguments::Obj(c.function.arguments),
                    },
                })
                .collect::<Vec<_>>()
        });
        ChatMessage {
            role: if self.role.is_empty() {
                "assistant".into()
            } else {
                self.role
            },
            content: self.content,
            tool_calls: tool_calls.filter(|v: &Vec<ToolCall>| !v.is_empty()),
            tool_call_id: None,
            name: None,
        }
    }
}
