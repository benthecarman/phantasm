pub mod presets;
pub mod research;
pub mod tools;
pub mod turn;

pub use presets::{PresetTable, ResearchPreset};
pub use turn::run_turn;

/// Transport-agnostic events produced by a turn. The chat route maps these to
/// OpenAI SSE chunks (streaming) or accumulates them into a single completion
/// (non-streaming).
#[derive(Debug, Clone)]
pub enum TurnEvent {
    /// Progress heartbeat, surfaced to the app via the additive `x_status` field.
    Status(String),
    /// A token of model thinking/reasoning, hidden by default in the app.
    Reasoning(String),
    /// A token of the final assistant answer.
    Token(String),
    /// App-hosted tool calls handed back to the app to execute. Emitted in place
    /// of a final answer and immediately followed by `Done { reason:
    /// "tool_calls" }`; the app fulfills them and resumes the turn next request.
    ToolCalls(Vec<crate::openai::types::ToolCall>),
    /// The turn finished; carries the OpenAI `finish_reason`.
    Done { reason: String },
    /// A terminal error after streaming began (cannot change HTTP status now).
    Error(String),
}
