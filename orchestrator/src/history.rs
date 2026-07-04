//! Repair for client-sent histories (XR-2: the app resends the full history
//! every turn, and any OpenAI-compatible client can talk to us).
//!
//! Adapted from goose's conversation fix-ups
//! (https://github.com/aaif-goose/goose, Apache-2.0,
//! `crates/goose-provider-types/src/conversation.rs`), reduced to the two
//! defects that make strict `/v1` upstreams reject the whole request with a
//! 400: a `tool`-role result answering no prior assistant call (truncated or
//! reordered client history), and an assistant `tool_calls` batch that never
//! got results (client cancelled mid-turn and resent what it had). Both are
//! excised so the turn proceeds on the coherent remainder; the model retries
//! naturally if the dropped exchange mattered.
//!
//! Goose's cosmetic passes (text merging, whitespace, placeholders for empty
//! results) are not ported — nothing downstream of us rejects those.

use std::collections::HashSet;

use crate::openai::types::ChatMessage;

/// What [`repair_history`] changed, for logging. Counts only — message
/// content never reaches logs un-gated (NFR-O7).
#[derive(Debug, Default, PartialEq)]
pub struct RepairSummary {
    /// `tool`-role messages dropped because no pending call matched their
    /// `tool_call_id` (unknown, duplicate, or arriving before the call).
    pub orphaned_results: usize,
    /// Assistant `tool_calls` entries excised because no result ever answered
    /// them.
    pub unanswered_calls: usize,
    /// Assistant messages dropped entirely because excising their calls left
    /// neither content nor calls.
    pub dropped_messages: usize,
}

impl RepairSummary {
    pub fn is_clean(&self) -> bool {
        *self == RepairSummary::default()
    }
}

/// Drop the parts of a client-sent history that a strict OpenAI-compatible
/// upstream rejects outright: orphaned tool results and never-answered tool
/// calls. A well-formed history passes through untouched.
///
/// Matching is by `tool_call_id`, so a history carrying id-less calls or
/// results (an Ollama-native-style client, where results pair by name) is
/// left entirely alone rather than half-repaired: those histories already
/// work on the upstreams that accept them, and id-based repair would wrongly
/// strip calls that their id-less results do answer.
pub fn repair_history(messages: &mut Vec<ChatMessage>) -> RepairSummary {
    let unmatchable = messages.iter().any(|m| {
        (m.role == "tool" && m.tool_call_id.is_none())
            || (m.role == "assistant"
                && m.tool_calls
                    .as_ref()
                    .is_some_and(|calls| calls.iter().any(|c| c.id.is_none())))
    });
    if unmatchable {
        return RepairSummary::default();
    }

    let mut summary = RepairSummary::default();

    // Forward pass: a result is kept iff it answers a call that is open at
    // that point. `pending` mirrors goose's tracker — ids move out of it as
    // they're answered, so a duplicate result for the same id is orphaned.
    let mut pending: HashSet<String> = HashSet::new();
    messages.retain(|m| {
        if m.role == "assistant" {
            if let Some(calls) = &m.tool_calls {
                pending.extend(calls.iter().filter_map(|c| c.id.clone()));
            }
            return true;
        }
        if m.role == "tool" {
            let id = m.tool_call_id.as_deref().expect("unmatchable checked");
            if pending.remove(id) {
                return true;
            }
            summary.orphaned_results += 1;
            return false;
        }
        true
    });

    // Whatever is still pending was never answered; excise those calls.
    if !pending.is_empty() {
        messages.retain_mut(|m| {
            if m.role != "assistant" {
                return true;
            }
            let Some(calls) = &mut m.tool_calls else {
                return true;
            };
            let before = calls.len();
            calls.retain(|c| !c.id.as_deref().is_some_and(|id| pending.contains(id)));
            summary.unanswered_calls += before - calls.len();
            if calls.is_empty() {
                m.tool_calls = None;
                if m.content.is_none() {
                    summary.dropped_messages += 1;
                    return false;
                }
            }
            true
        });
    }

    summary
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::openai::types::{FunctionCall, MessageContent, RawArguments, ToolCall};

    fn user(text: &str) -> ChatMessage {
        ChatMessage {
            role: "user".into(),
            content: Some(MessageContent::Text(text.into())),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    fn call(id: Option<&str>) -> ToolCall {
        ToolCall {
            id: id.map(str::to_string),
            kind: "function".into(),
            function: FunctionCall {
                name: "time".into(),
                arguments: RawArguments::Str("{}".into()),
            },
        }
    }

    fn assistant_calls(content: Option<&str>, ids: &[Option<&str>]) -> ChatMessage {
        ChatMessage {
            role: "assistant".into(),
            content: content.map(|t| MessageContent::Text(t.into())),
            tool_calls: Some(ids.iter().map(|id| call(*id)).collect()),
            tool_call_id: None,
            name: None,
        }
    }

    fn result(id: &str) -> ChatMessage {
        ChatMessage::tool_result(id, "time", "12:00")
    }

    #[test]
    fn well_formed_history_is_untouched() {
        let mut messages = vec![
            user("hi"),
            assistant_calls(None, &[Some("a"), Some("b")]),
            result("a"),
            result("b"),
            user("thanks"),
        ];
        let original = messages.clone();
        let summary = repair_history(&mut messages);
        assert!(summary.is_clean());
        assert_eq!(messages.len(), original.len());
    }

    #[test]
    fn orphaned_result_is_dropped() {
        let mut messages = vec![user("hi"), result("ghost"), user("still here")];
        let summary = repair_history(&mut messages);
        assert_eq!(summary.orphaned_results, 1);
        assert_eq!(messages.len(), 2);
        assert!(messages.iter().all(|m| m.role != "tool"));
    }

    #[test]
    fn duplicate_result_for_same_call_is_dropped() {
        let mut messages = vec![
            user("hi"),
            assistant_calls(None, &[Some("a")]),
            result("a"),
            result("a"),
        ];
        let summary = repair_history(&mut messages);
        assert_eq!(summary.orphaned_results, 1);
        assert_eq!(messages.iter().filter(|m| m.role == "tool").count(), 1);
    }

    #[test]
    fn result_arriving_before_its_call_is_dropped() {
        let mut messages = vec![user("hi"), result("a"), assistant_calls(None, &[Some("a")])];
        let summary = repair_history(&mut messages);
        // The early result is orphaned, which in turn leaves the call
        // unanswered — both sides of the broken pair go.
        assert_eq!(summary.orphaned_results, 1);
        assert_eq!(summary.unanswered_calls, 1);
        assert_eq!(summary.dropped_messages, 1);
        assert_eq!(messages.len(), 1);
    }

    #[test]
    fn unanswered_call_is_excised_and_bare_message_dropped() {
        let mut messages = vec![user("hi"), assistant_calls(None, &[Some("a")]), user("?")];
        let summary = repair_history(&mut messages);
        assert_eq!(summary.unanswered_calls, 1);
        assert_eq!(summary.dropped_messages, 1);
        assert_eq!(messages.len(), 2);
    }

    #[test]
    fn unanswered_call_keeps_message_with_content() {
        let mut messages = vec![
            user("hi"),
            assistant_calls(Some("checking..."), &[Some("a"), Some("b")]),
            result("b"),
        ];
        let summary = repair_history(&mut messages);
        assert_eq!(summary.unanswered_calls, 1);
        assert_eq!(summary.dropped_messages, 0);
        let assistant = &messages[1];
        assert_eq!(assistant.tool_calls.as_ref().unwrap().len(), 1);
        assert_eq!(
            assistant.tool_calls.as_ref().unwrap()[0].id.as_deref(),
            Some("b")
        );
        assert!(assistant.content.is_some());
    }

    #[test]
    fn idless_histories_are_left_alone() {
        // Ollama-native-style pairing (no ids anywhere): repair must not
        // guess, even though an id-based match would call all of this broken.
        let mut messages = vec![
            user("hi"),
            assistant_calls(None, &[None]),
            ChatMessage {
                tool_call_id: None,
                ..ChatMessage::tool_result("x", "time", "12:00")
            },
        ];
        let original_len = messages.len();
        let summary = repair_history(&mut messages);
        assert!(summary.is_clean());
        assert_eq!(messages.len(), original_len);
    }

    #[test]
    fn plain_history_without_tools_is_untouched() {
        let mut messages = vec![user("hi"), user("hello again")];
        let summary = repair_history(&mut messages);
        assert!(summary.is_clean());
        assert_eq!(messages.len(), 2);
    }
}
