use std::future::Future;

use serde::de::DeserializeOwned;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::ToolOutcome;
use crate::orchestrator::TurnEvent;

pub mod audio_gen;
pub mod calculator;
pub mod code_exec;
pub mod code_exec_pool;
pub mod comfy;
pub mod github;
pub mod http_util;
pub mod image_delivery;
pub mod image_edit;
pub mod image_gen;
pub mod maps_places;
pub mod market_data;
pub mod ocr;
pub mod sports;
pub mod time;
pub mod unit_convert;
pub mod weather;
pub mod web_fetch;
pub mod web_search;

/// The `tool`-role message a failure folds into: the uniform
/// `"<tool> failed: <detail>"` text. Tool errors are non-fatal (NFR-O6) — this
/// is a normal tool result the model reads and continues from, never a fatal
/// error propagated up.
pub(crate) fn error_outcome(tool: &str, call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(call_id, tool, format!("{tool} failed: {detail}")),
        append_to_answer: None,
        is_error: true,
    }
}

/// The run() skeleton shared by the plain tools: parse the arguments, announce
/// a status, run the operation `select!`ed against cancellation, and fold any
/// failure into the tool message via [`error_outcome`]. `status` sees the
/// parsed arguments so tools with per-call statuses (maps_places) fit too.
///
/// Tools with extra shape — a failure-status event (web_search, image_gen/
/// edit), pre-status validation (code_exec, image_edit), non-standard message
/// strings (time), or an `append_to_answer` (image tools) — keep their own
/// run() rather than bending this one.
pub(crate) async fn run_simple<A, Fut>(
    tool: &'static str,
    call: &ToolCall,
    call_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
    status: impl FnOnce(&A) -> String,
    op: impl FnOnce(A) -> Fut,
) -> ToolOutcome
where
    A: DeserializeOwned,
    Fut: Future<Output = Result<String, String>>,
{
    let args: A = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(tool, call_id, format!("invalid arguments: {e}")),
    };
    let _ = tx.send(TurnEvent::Status(status(&args))).await;

    let result = tokio::select! {
        r = op(args) => r,
        _ = cancel.cancelled() => return error_outcome(tool, call_id, "cancelled".into()),
    };

    match result {
        Ok(text) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, tool, text),
            append_to_answer: None,
            is_error: false,
        },
        Err(e) => {
            tracing::warn!(error = %e, tool, "tool call failed");
            error_outcome(tool, call_id, e)
        }
    }
}
