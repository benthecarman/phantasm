//! Current server time utility. Pure local clock read; no network, filesystem,
//! or shell access.

use chrono::{SecondsFormat, Utc};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct TimeArgs {}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(TimeArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "time",
        "Get the current server time in UTC. Use this for current date or time questions instead of guessing.",
        params,
    )
}

pub async fn run(
    _call: &ToolCall,
    call_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let _ = tx.send(TurnEvent::Status("checking time...".into())).await;

    tokio::select! {
        result = async { current_time_result() } => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "time", result),
            append_to_answer: None,
            is_error: false,
        },
        _ = cancel.cancelled() => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "time", "time lookup cancelled"),
            append_to_answer: None,
            is_error: true,
        },
    }
}

fn current_time_result() -> String {
    let now = Utc::now();
    format!(
        "Current server time:\ntimezone: UTC\nutc_datetime: {}\nunix_timestamp: {}\nunix_millis: {}",
        now.to_rfc3339_opts(SecondsFormat::Millis, true),
        now.timestamp(),
        now.timestamp_millis()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::openai::types::{FunctionCall, MessageContent, RawArguments, ToolCall};

    #[test]
    fn schema_names_time() {
        let schema = schema();
        assert_eq!(schema["function"]["name"], "time");
    }

    #[tokio::test]
    async fn run_returns_utc_timestamp_and_status() {
        let call = ToolCall {
            id: Some("call_1".into()),
            kind: "function".into(),
            function: FunctionCall {
                name: "time".into(),
                arguments: RawArguments::Obj(serde_json::json!({})),
            },
        };
        let (tx, mut rx) = mpsc::channel(4);
        let outcome = run(&call, "call_1", &tx, &CancellationToken::new()).await;
        let status = rx.recv().await.expect("status event");
        assert!(matches!(status, TurnEvent::Status(s) if s == "checking time..."));
        assert_eq!(outcome.message.tool_call_id.as_deref(), Some("call_1"));
        assert_eq!(outcome.message.name.as_deref(), Some("time"));
        let content = match outcome.message.content.expect("tool result content") {
            MessageContent::Text(text) => text,
            MessageContent::Parts(_) => panic!("time result should be text"),
        };
        assert!(content.contains("timezone: UTC"));
        assert!(content.contains("utc_datetime:"));
        assert!(content.contains("unix_timestamp:"));
    }
}
