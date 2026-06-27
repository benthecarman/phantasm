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
    /// App-hosted tool calls handed back to the app to execute, emitted in place
    /// of a final answer and immediately followed by `Done { reason:
    /// "tool_calls" }`. The app fulfills them and resumes the turn next request.
    ///
    /// `held` carries the full turn history *with* any co-occurring server calls
    /// already executed and their results appended — stashed server-side so the
    /// continuation request can resume from it (the server tools stay invisible
    /// to the app). `None` when no server calls co-occurred: the app's own
    /// re-sent history is already complete, so nothing needs holding.
    ToolCalls {
        app: Vec<crate::openai::types::ToolCall>,
        held: Option<Vec<crate::openai::types::ChatMessage>>,
    },
    /// The turn finished; carries the OpenAI `finish_reason`.
    Done { reason: String },
    /// A terminal error after streaming began (cannot change HTTP status now).
    Error(String),
}
