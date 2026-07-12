//! OpenAI-compatible wire types — the surface the iOS app talks to.
//!
//! We keep these intentionally permissive: unknown fields on the incoming
//! request are preserved opaquely so a future client can pass parameters we
//! don't model yet without us rejecting them.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Whether the client requested model "thinking" for this turn, read from the
/// OpenAI-compatible reasoning controls in a request's pass-through options:
/// `reasoning_effort` (string) or the nested `reasoning.effort` (string).
/// `"none"` (case-insensitive) => thinking off; any other value => on; absent =>
/// `None` (no preference). Shared by both upstream backends so the one wire
/// contract for reasoning effort lives in a single place.
pub(crate) fn requested_thinking(options: &serde_json::Map<String, Value>) -> Option<bool> {
    const NONE: &str = "none";
    if let Some(effort) = options.get("reasoning_effort").and_then(Value::as_str) {
        return Some(!effort.eq_ignore_ascii_case(NONE));
    }
    options
        .get("reasoning")
        .and_then(Value::as_object)
        .and_then(|reasoning| reasoning.get("effort"))
        .and_then(Value::as_str)
        .map(|effort| !effort.eq_ignore_ascii_case(NONE))
}

/// Incoming `POST /v1/chat/completions` body.
#[derive(Debug, Clone, Deserialize)]
pub struct ChatRequest {
    #[serde(default)]
    pub model: Option<String>,
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub stream: bool,
    /// Standard OpenAI `tools` array, used two ways (spec §2.3):
    ///   * **Server-tool selection by name** — a *name-only* entry
    ///     (`{"type":"function","function":{"name":"web_search"}}` or the built-in
    ///     shorthand `{"type":"web_search"}`) selects a server-side tool the
    ///     deployment hosts. See [`Self::tool_selection`].
    ///   * **App-hosted tool definition** — an entry that carries a full
    ///     `function.parameters` schema is a tool the *app* executes. The server
    ///     offers it to the model and forwards any call back to the app rather
    ///     than running it. See [`Self::app_tools`].
    ///
    /// On a name collision the server-side tool wins (the app entry is dropped),
    /// resolved in the chat route. Field absent => offer every configured server
    /// tool and no app tools.
    #[serde(default)]
    pub tools: Option<Vec<ToolSpec>>,
    /// Standard OpenAI `tool_choice`. `"none"` forces plain chat. A specific
    /// function choice narrows selection to that tool and is forwarded upstream
    /// during tool resolution.
    #[serde(default)]
    pub tool_choice: Option<Value>,
    /// Any other OpenAI sampling parameters (temperature, top_p, …) passed through to Ollama.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}

/// One entry of the standard OpenAI `tools` array. A name-only entry selects a
/// configured server tool; an entry carrying `function.parameters` defines an
/// app-hosted tool (the app executes it).
#[derive(Debug, Clone, Deserialize)]
pub struct ToolSpec {
    #[serde(rename = "type", default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub function: Option<ToolSpecFunction>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ToolSpecFunction {
    pub name: String,
    /// Present only for app-hosted tool definitions.
    #[serde(default)]
    pub description: Option<String>,
    /// The JSON-Schema parameters. Its presence is what marks this entry as an
    /// app-hosted tool (a server-tool selector is name-only).
    #[serde(default)]
    pub parameters: Option<Value>,
}

impl ToolSpec {
    /// The server-tool name this entry selects: the function name for a standard
    /// function tool, or the `type` itself for a built-in-tool entry such as
    /// `{"type":"web_search"}`. `None` for an unnamed/`function`-typed-but-empty
    /// entry, which the selection then simply ignores.
    fn selected_name(&self) -> Option<String> {
        if let Some(f) = &self.function {
            return Some(f.name.clone());
        }
        match self.kind.as_deref() {
            Some(kind) if kind != "function" => Some(kind.to_string()),
            _ => None,
        }
    }
}

impl ChatRequest {
    fn forced_tool_choice_name(&self) -> Option<String> {
        let choice = self.tool_choice.as_ref()?.as_object()?;
        if choice.get("type").and_then(Value::as_str) != Some("function") {
            return None;
        }
        choice
            .get("function")
            .and_then(Value::as_object)
            .and_then(|function| function.get("name"))
            .and_then(Value::as_str)
            .map(str::to_string)
    }

    /// The `tool_choice` value that should be forwarded to an OpenAI-compatible
    /// upstream. `none` is handled locally by offering no tools. Native Ollama
    /// ignores this, since `/api/chat` has no matching forced-tool-choice field.
    pub fn upstream_tool_choice(&self) -> Option<Value> {
        match self.tool_choice.as_ref()? {
            Value::String(s) if matches!(s.as_str(), "auto" | "required") => {
                Some(Value::String(s.clone()))
            }
            Value::Object(_) if self.forced_tool_choice_name().is_some() => {
                self.tool_choice.clone()
            }
            _ => None,
        }
    }

    /// Resolve the per-turn tool selection from the standard `tools`/`tool_choice`
    /// fields into the orchestrator's narrowing list. `None` => offer every
    /// configured tool (field absent — older clients). `Some(list)` => offer only
    /// those names (an empty list, or `tool_choice:"none"`, => plain chat).
    ///
    /// Names are intersected with the configured tools downstream
    /// ([`select_schemas`](crate::orchestrator::turn::select_schemas)), so a
    /// client can never add a tool the deployment lacks.
    pub fn tool_selection(&self) -> Option<Vec<String>> {
        if self.tool_choice.as_ref().and_then(Value::as_str) == Some("none") {
            return Some(Vec::new());
        }
        if let Some(name) = self.forced_tool_choice_name() {
            return Some(vec![name]);
        }
        self.tools
            .as_ref()
            .map(|list| list.iter().filter_map(ToolSpec::selected_name).collect())
    }

    /// App-hosted tool definitions from the `tools` array: every entry that
    /// carries a `function.parameters` schema, rebuilt into the OpenAI tool
    /// envelope offered to the model. `tool_choice:"none"` (or no `tools`) => no
    /// app tools. Calls to these tools are forwarded to the app to execute; the
    /// chat route drops any whose name collides with a configured server tool
    /// (server wins).
    pub fn app_tools(&self) -> Vec<Value> {
        if self.tool_choice.as_ref().and_then(Value::as_str) == Some("none") {
            return Vec::new();
        }
        let forced = self.forced_tool_choice_name();
        let Some(list) = &self.tools else {
            return Vec::new();
        };
        list.iter()
            .filter_map(|spec| {
                let f = spec.function.as_ref()?;
                if forced.as_ref().is_some_and(|forced| forced != &f.name) {
                    return None;
                }
                let parameters = f.parameters.clone()?;
                let mut function = serde_json::Map::new();
                function.insert("name".into(), Value::String(f.name.clone()));
                if let Some(desc) = &f.description {
                    function.insert("description".into(), Value::String(desc.clone()));
                }
                function.insert("parameters".into(), parameters);
                Some(json!({ "type": "function", "function": Value::Object(function) }))
            })
            .collect()
    }
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

    pub fn user(content: impl Into<String>) -> Self {
        ChatMessage {
            role: "user".into(),
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
    /// native per-message `images` field. Owned variant of [`Self::to_text_and_images`].
    pub fn into_text_and_images(self) -> (Option<String>, Vec<String>) {
        self.to_text_and_images()
    }

    /// Borrowing form of [`Self::into_text_and_images`] for the hot Ollama
    /// conversion path: the two-phase turn loop re-issues the upstream call
    /// several times per turn, and cloning the whole (possibly multi-MB) content
    /// just to split it is pure waste. Same result, no `self` clone.
    pub fn to_text_and_images(&self) -> (Option<String>, Vec<String>) {
        match self {
            MessageContent::Text(s) => (Some(s.clone()), Vec::new()),
            MessageContent::Parts(parts) => {
                let mut texts = Vec::new();
                let mut images = Vec::new();
                for part in parts {
                    match part {
                        ContentPart::Text { text } => texts.push(text.clone()),
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

    /// Server-hosted blob ids referenced by `/v1/files/<id>/content` links in
    /// this content — whether in an `image_url` part or in markdown text (the
    /// form a generated image takes once delivered as a URL). The turn loop
    /// resolves these against the store so the edit tool sees bytes, not a link.
    pub fn store_image_ids(&self) -> Vec<String> {
        match self {
            MessageContent::Text(s) => extract_markdown_image_store_ids(s),
            MessageContent::Parts(parts) => parts
                .iter()
                .flat_map(|p| match p {
                    ContentPart::ImageUrl { image_url } => extract_store_ids(&image_url.url),
                    ContentPart::Text { text } => extract_markdown_image_store_ids(text),
                })
                .collect(),
        }
    }
}

/// Extract Files-style ids only from Markdown image targets. Ordinary links may
/// be generated audio/video; those must not be decoded into the image-edit
/// context merely because they share the same signed blob route.
fn extract_markdown_image_store_ids(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = s;
    while let Some(start) = rest.find("![") {
        let image = &rest[start + 2..];
        let Some(target_start) = image.find("](") else {
            break;
        };
        let target = &image[target_start + 2..];
        let Some(target_end) = target.find(')') else {
            break;
        };
        out.extend(extract_store_ids(&target[..target_end]));
        rest = &target[target_end + 1..];
    }
    out
}

/// Pull every `<id>` out of `/v1/files/<id>/content` occurrences in `s` (id =
/// our base64url charset, terminated by `/`, `?`, `)`, quote, whitespace, …).
pub(crate) fn extract_store_ids(s: &str) -> Vec<String> {
    const MARKER: &str = "/v1/files/";
    let mut out = Vec::new();
    let mut rest = s;
    while let Some(idx) = rest.find(MARKER) {
        let after = &rest[idx + MARKER.len()..];
        let end = after
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
            .unwrap_or(after.len());
        if end > 0 {
            out.push(after[..end].to_string());
        }
        rest = &after[end..];
    }
    out
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

    fn req(json: &str) -> ChatRequest {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn tool_selection_absent_offers_all() {
        let r = req(r#"{"messages":[]}"#);
        assert_eq!(r.tool_selection(), None);
    }

    #[test]
    fn tool_selection_empty_array_is_plain_chat() {
        let r = req(r#"{"messages":[],"tools":[]}"#);
        assert_eq!(r.tool_selection(), Some(vec![]));
    }

    #[test]
    fn tool_selection_reads_function_names() {
        let r = req(
            r#"{"messages":[],"tools":[{"type":"function","function":{"name":"web_search"}}]}"#,
        );
        assert_eq!(r.tool_selection(), Some(vec!["web_search".to_string()]));
    }

    #[test]
    fn tool_selection_reads_builtin_tool_type() {
        // The OpenAI built-in-tool shorthand: the `type` itself names the tool.
        let r = req(r#"{"messages":[],"tools":[{"type":"web_search"}]}"#);
        assert_eq!(r.tool_selection(), Some(vec!["web_search".to_string()]));
    }

    #[test]
    fn tool_choice_none_forces_plain_chat() {
        let r = req(
            r#"{"messages":[],"tool_choice":"none","tools":[{"type":"function","function":{"name":"web_search"}}]}"#,
        );
        assert_eq!(r.tool_selection(), Some(vec![]));
    }

    #[test]
    fn forced_tool_choice_selects_only_that_tool_and_forwards_upstream() {
        let r = req(
            r#"{"messages":[],"tool_choice":{"type":"function","function":{"name":"time"}},"tools":[
                {"type":"function","function":{"name":"calculator"}},
                {"type":"function","function":{"name":"time"}}
            ]}"#,
        );
        assert_eq!(r.tool_selection(), Some(vec!["time".to_string()]));
        assert_eq!(
            r.upstream_tool_choice().unwrap()["function"]["name"],
            "time"
        );
    }

    #[test]
    fn tool_choice_auto_and_required_forward_upstream() {
        let auto = req(r#"{"messages":[],"tool_choice":"auto"}"#);
        assert_eq!(
            auto.upstream_tool_choice(),
            Some(Value::String("auto".into()))
        );

        let required = req(r#"{"messages":[],"tool_choice":"required"}"#);
        assert_eq!(
            required.upstream_tool_choice(),
            Some(Value::String("required".into()))
        );

        let none = req(r#"{"messages":[],"tool_choice":"none"}"#);
        assert_eq!(none.upstream_tool_choice(), None);
    }

    #[test]
    fn forced_tool_choice_filters_app_tools_too() {
        let r = req(
            r#"{"messages":[],"tool_choice":{"type":"function","function":{"name":"ask_user"}},"tools":[
                {"type":"function","function":{"name":"ask_user","parameters":{"type":"object"}}},
                {"type":"function","function":{"name":"other_app","parameters":{"type":"object"}}}
            ]}"#,
        );
        let app = r.app_tools();
        assert_eq!(app.len(), 1);
        assert_eq!(app[0]["function"]["name"], "ask_user");
    }

    #[test]
    fn app_tools_extracts_only_schema_bearing_entries() {
        // A name-only entry selects a server tool; an entry with `parameters`
        // is an app-hosted tool definition.
        let r = req(r#"{"messages":[],"tools":[
                {"type":"function","function":{"name":"web_search"}},
                {"type":"function","function":{"name":"ask_user","description":"ask","parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}
            ]}"#);
        let app = r.app_tools();
        assert_eq!(app.len(), 1, "only the schema-bearing entry is an app tool");
        assert_eq!(app[0]["function"]["name"], "ask_user");
        assert_eq!(app[0]["function"]["description"], "ask");
        assert!(app[0]["function"]["parameters"]["properties"]["q"].is_object());
        // The name-only server tool is still surfaced via tool_selection.
        assert_eq!(
            r.tool_selection(),
            Some(vec!["web_search".to_string(), "ask_user".to_string()])
        );
    }

    #[test]
    fn app_tools_omits_description_when_absent() {
        let r = req(
            r#"{"messages":[],"tools":[{"type":"function","function":{"name":"t","parameters":{"type":"object"}}}]}"#,
        );
        let app = r.app_tools();
        assert!(app[0]["function"].get("description").is_none());
    }

    #[test]
    fn app_tools_empty_when_tool_choice_none() {
        let r = req(
            r#"{"messages":[],"tool_choice":"none","tools":[{"type":"function","function":{"name":"ask_user","parameters":{"type":"object"}}}]}"#,
        );
        assert!(r.app_tools().is_empty());
    }

    #[test]
    fn raw_arguments_to_json_string() {
        assert_eq!(
            RawArguments::Obj(serde_json::json!({"a":1})).to_json_string(),
            "{\"a\":1}"
        );
        assert_eq!(
            RawArguments::Str("{\"a\":1}".into()).to_json_string(),
            "{\"a\":1}"
        );
    }

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
    fn stored_audio_link_is_not_treated_as_an_editable_image() {
        let content = MessageContent::Text(
            "![image](https://h/v1/files/img/content?exp=1&sig=x) \
             [Audio: clip](https://h/v1/files/sound/content?exp=1&sig=x)"
                .into(),
        );
        assert_eq!(content.store_image_ids(), ["img"]);
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

/// Mint a synthetic tool-call id in the OpenAI style. Used wherever an
/// upstream supplies calls without ids (native Ollama, XML fallback, SSE
/// deltas missing them) so downstream correlation always has one, in one
/// consistent format.
pub(crate) fn mint_call_id() -> String {
    format!("call_{}", uuid::Uuid::new_v4().simple())
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

    /// Render the arguments as the JSON-encoded *string* the OpenAI wire format
    /// uses for `tool_calls[].function.arguments` (both in streaming deltas and
    /// the non-streaming message), regardless of how they arrived.
    pub fn to_json_string(&self) -> String {
        match self {
            RawArguments::Str(s) => s.clone(),
            RawArguments::Obj(v) => serde_json::to_string(v).unwrap_or_else(|_| "{}".into()),
        }
    }
}

// ---- Streaming chunk emitted to the client ----

/// One `chat.completion.chunk` SSE event. `x_status` / `x_progress` are
/// additive, non-standard fields (spec §2.3): strict OpenAI clients ignore them,
/// our app reads them for progress.
#[derive(Debug, Clone, Serialize)]
pub struct ChatChunk {
    pub id: String,
    pub object: &'static str,
    pub created: i64,
    pub model: String,
    pub choices: Vec<ChunkChoice>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x_progress: Option<f64>,
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
    /// Streamed model reasoning. Serialized as `reasoning_content` to match the
    /// de-facto OpenAI-compat convention (DeepSeek/vLLM/OpenRouter), so any
    /// standard client that understands reasoning renders it — not just our app.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_content: Option<String>,
    /// Forwarded app-hosted tool calls (standard OpenAI streaming shape). Present
    /// only on the chunk that hands a tool call back to the app to execute.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<DeltaToolCall>>,
}

impl Delta {
    pub fn role(role: impl Into<String>) -> Self {
        Delta {
            role: Some(role.into()),
            ..Default::default()
        }
    }

    pub fn content(content: impl Into<String>) -> Self {
        Delta {
            content: Some(content.into()),
            ..Default::default()
        }
    }

    pub fn reasoning(reasoning: impl Into<String>) -> Self {
        Delta {
            reasoning_content: Some(reasoning.into()),
            ..Default::default()
        }
    }

    pub fn tool_calls(calls: Vec<DeltaToolCall>) -> Self {
        Delta {
            tool_calls: Some(calls),
            ..Default::default()
        }
    }
}

/// One entry of a streaming `delta.tool_calls` array (OpenAI shape). `arguments`
/// is a JSON-encoded *string*, not an object.
#[derive(Debug, Clone, Serialize)]
pub struct DeltaToolCall {
    pub index: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub function: DeltaFunctionCall,
}

#[derive(Debug, Clone, Serialize)]
pub struct DeltaFunctionCall {
    pub name: String,
    pub arguments: String,
}
