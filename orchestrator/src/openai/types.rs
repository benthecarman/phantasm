//! OpenAI-compatible wire types — the surface the iOS app talks to.
//!
//! We keep these intentionally permissive: unknown fields on the incoming
//! request are preserved opaquely so a future client can pass parameters we
//! don't model yet without us rejecting them.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Incoming `POST /v1/chat/completions` body.
#[derive(Debug, Clone, Deserialize)]
pub struct ChatRequest {
    #[serde(default)]
    pub model: Option<String>,
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub stream: bool,
    /// Additive, non-standard request field (spec §2.3 `x_`-prefix convention):
    /// the subset of server tools the client wants offered this turn, by name
    /// (e.g. `["web_search"]`). `None` (field absent) => offer every usable tool,
    /// keeping older clients working. An empty list => offer none (plain chat).
    /// The server always intersects this with what is actually configured, so a
    /// client can never enable a tool the deployment lacks.
    #[serde(default, rename = "x_tools")]
    pub enabled_tools: Option<Vec<String>>,
    /// Additive, non-standard request field (spec §2.3 `x_`-prefix convention):
    /// run this turn in Deep Research mode. The server then injects a research
    /// system prompt, offers only `web_search` (forcing full-page fetching
    /// regardless of `SEARCH_FETCH_PAGES`), and uses a larger iteration budget.
    /// Absent/false => an ordinary turn. Standard clients omit it entirely.
    #[serde(default, rename = "x_research")]
    pub research: bool,
    /// Any other OpenAI sampling parameters (temperature, top_p, …) passed through to Ollama.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<MessageContent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCall>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

impl ChatMessage {
    pub fn system(content: impl Into<String>) -> Self {
        ChatMessage {
            role: "system".into(),
            content: Some(MessageContent::Text(content.into())),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    pub fn tool_result(
        tool_call_id: impl Into<String>,
        name: impl Into<String>,
        content: impl Into<String>,
    ) -> Self {
        ChatMessage {
            role: "tool".into(),
            content: Some(MessageContent::Text(content.into())),
            tool_calls: None,
            tool_call_id: Some(tool_call_id.into()),
            name: Some(name.into()),
        }
    }
}

/// A message's `content`: either a plain string (the common case, and what raw
/// Ollama emits) or the OpenAI multimodal content-parts array. Modelling both
/// keeps us a drop-in OpenAI server while letting the app attach images
/// (`image_url` parts) and inlined file text (extra `text` parts).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum MessageContent {
    Text(String),
    Parts(Vec<ContentPart>),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ContentPart {
    Text { text: String },
    ImageUrl { image_url: ImageUrl },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageUrl {
    /// Either a remote URL or a `data:<mime>;base64,<payload>` data URI.
    pub url: String,
}

impl MessageContent {
    /// Split into (concatenated text, base64 image payloads). Data-URI prefixes
    /// (`data:<mime>;base64,`) are stripped so the payload is ready for Ollama's
    /// native per-message `images` field.
    pub fn into_text_and_images(self) -> (Option<String>, Vec<String>) {
        match self {
            MessageContent::Text(s) => (Some(s), Vec::new()),
            MessageContent::Parts(parts) => {
                let mut texts = Vec::new();
                let mut images = Vec::new();
                for part in parts {
                    match part {
                        ContentPart::Text { text } => texts.push(text),
                        ContentPart::ImageUrl { image_url } => {
                            images.push(strip_data_uri(&image_url.url));
                        }
                    }
                }
                let text = if texts.is_empty() {
                    None
                } else {
                    Some(texts.join("\n"))
                };
                (text, images)
            }
        }
    }

    /// Borrowing variant of [`Self::into_text_and_images`] that yields just the
    /// base64 image payloads (data-URI prefixes stripped), leaving the message
    /// intact. Used to surface images to the edit tool — both a user's attached
    /// `image_url` parts and images embedded as `data:` URIs in text (e.g. the
    /// `![generated](data:…)` markdown the image tools emit into an assistant
    /// answer), so the model can edit something generated earlier. Document
    /// order is preserved so callers can treat the last entry as most recent.
    pub fn image_payloads(&self) -> Vec<String> {
        match self {
            MessageContent::Text(s) => embedded_data_uri_payloads(s),
            MessageContent::Parts(parts) => parts
                .iter()
                .flat_map(|p| match p {
                    ContentPart::ImageUrl { image_url } => vec![strip_data_uri(&image_url.url)],
                    ContentPart::Text { text } => embedded_data_uri_payloads(text),
                })
                .collect(),
        }
    }
}

/// Pull the base64 payload out of every `data:<mime>;base64,<payload>` URI
/// embedded in free text (in markdown order). Used to recover images the image
/// tools wrote into an assistant message as `![…](data:…)` markdown.
fn embedded_data_uri_payloads(text: &str) -> Vec<String> {
    const MARKER: &str = ";base64,";
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(idx) = rest.find(MARKER) {
        let after = &rest[idx + MARKER.len()..];
        let end = after
            .find(|c: char| !is_base64_char(c))
            .unwrap_or(after.len());
        if end > 0 {
            out.push(after[..end].to_string());
        }
        rest = &after[end..];
    }
    out
}

fn is_base64_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=')
}

/// Strip a `data:<mime>;base64,` prefix, yielding the raw base64 payload. A bare
/// URL (or already-bare base64) is returned unchanged.
fn strip_data_uri(url: &str) -> String {
    if let Some(idx) = url.find(";base64,") {
        url[idx + ";base64,".len()..].to_string()
    } else {
        url.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_string_content_still_parses() {
        let m: ChatMessage = serde_json::from_str(r#"{"role":"user","content":"hi"}"#).unwrap();
        assert!(matches!(m.content, Some(MessageContent::Text(ref s)) if s == "hi"));
    }

    #[test]
    fn content_parts_parse_and_split() {
        let json = r#"{
            "role":"user",
            "content":[
                {"type":"text","text":"what is this?"},
                {"type":"image_url","image_url":{"url":"data:image/png;base64,QUJD"}}
            ]
        }"#;
        let m: ChatMessage = serde_json::from_str(json).unwrap();
        let (text, images) = m.content.unwrap().into_text_and_images();
        assert_eq!(text.as_deref(), Some("what is this?"));
        assert_eq!(images, vec!["QUJD".to_string()]);
    }

    #[test]
    fn bare_url_is_not_stripped() {
        assert_eq!(strip_data_uri("https://x/y.png"), "https://x/y.png");
        assert_eq!(strip_data_uri("data:image/jpeg;base64,ZZZ"), "ZZZ");
    }

    #[test]
    fn text_content_yields_embedded_generated_images() {
        // The markdown the image tools emit into an assistant answer.
        let c = MessageContent::Text(
            "Here you go!\n\n![generated](data:image/png;base64,R0lGODlh)".into(),
        );
        assert_eq!(c.image_payloads(), vec!["R0lGODlh".to_string()]);
    }

    #[test]
    fn embedded_extractor_handles_multiple_and_terminators() {
        let payloads = embedded_data_uri_payloads(
            "a ![x](data:image/png;base64,AAA) b ![y](data:image/jpeg;base64,BBB==) c",
        );
        assert_eq!(payloads, vec!["AAA".to_string(), "BBB==".to_string()]);
    }

    #[test]
    fn plain_text_has_no_images() {
        assert!(MessageContent::Text("just words".into())
            .image_payloads()
            .is_empty());
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(rename = "type", default = "default_tool_type")]
    pub kind: String,
    pub function: FunctionCall,
}

fn default_tool_type() -> String {
    "function".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionCall {
    pub name: String,
    /// OpenAI sends arguments as a JSON-encoded *string*; Ollama sends an object.
    /// `RawArguments` normalizes both.
    pub arguments: RawArguments,
}

/// Tool-call arguments, tolerant of both the OpenAI (stringified JSON) and
/// Ollama-native (JSON object) encodings.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RawArguments {
    Str(String),
    Obj(Value),
}

impl RawArguments {
    /// Parse the arguments into a concrete type.
    pub fn parse<T: for<'de> Deserialize<'de>>(&self) -> Result<T, serde_json::Error> {
        match self {
            RawArguments::Str(s) => serde_json::from_str(s),
            RawArguments::Obj(v) => serde_json::from_value(v.clone()),
        }
    }
}

// ---- Streaming chunk emitted to the client ----

/// One `chat.completion.chunk` SSE event. `x_status` is an additive,
/// non-standard field (spec §2.3): strict OpenAI clients ignore it, our app
/// reads it for progress.
#[derive(Debug, Clone, Serialize)]
pub struct ChatChunk {
    pub id: String,
    pub object: &'static str,
    pub created: i64,
    pub model: String,
    pub choices: Vec<ChunkChoice>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x_status: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChunkChoice {
    pub index: u32,
    pub delta: Delta,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finish_reason: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Delta {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<String>,
}

impl Delta {
    pub fn role(role: impl Into<String>) -> Self {
        Delta {
            role: Some(role.into()),
            content: None,
            reasoning: None,
        }
    }

    pub fn content(content: impl Into<String>) -> Self {
        Delta {
            role: None,
            content: Some(content.into()),
            reasoning: None,
        }
    }

    pub fn reasoning(reasoning: impl Into<String>) -> Self {
        Delta {
            role: None,
            content: None,
            reasoning: Some(reasoning.into()),
        }
    }
}
