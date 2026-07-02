//! Deep Research engine: an orchestrator/worker pipeline with **context
//! isolation** (the core invariant) and a separate synthesis stage, sized down
//! to one self-hosted Ollama backend.
//!
//! Entered from [`crate::orchestrator::run_turn`] when the resolved model carries
//! a research preset. Plain and ordinary tool turns keep their existing fast
//! paths untouched (NFR-O3).
//!
//! Four stages, each with its **own** message context:
//!
//! 1. **PLAN** — one `chat_once` with the planner prompt → `{ brief,
//!    sub_questions }`. Parsed defensively; on failure we fall back to a single
//!    sub-question equal to the user's question.
//! 2. **RESEARCH** — for each sub-question an *isolated* sub-agent: a FRESH
//!    `[system(subagent_prompt), user(sub_q)]` messages vec runs a bounded
//!    web_search-only tool loop, then a compression call distills its transcript
//!    into a short finding + the URLs it actually used. The lead never sees raw
//!    pages — only findings. Sub-agents run with bounded concurrency.
//! 3. **SYNTHESIZE** — `[system(synth_prompt), user(brief + findings + numbered
//!    sources)]`. When `verify` is false we stream the answer live; when true we
//!    draft non-streaming first, run stage 4, then emit the corrected answer.
//! 4. **VERIFY/CITE** (preset-gated) — a `chat_once` that drops/repairs any `[n]`
//!    not backed by a fetched URL, returning a corrected answer.
//!
//! Context flow (the actual fix for blowup):
//! ```text
//! history ─plan─▶ brief ─┬─▶ sub-agent 1 (own ctx) ─▶ finding 1 ─┐
//!                        ├─▶ sub-agent 2 (own ctx) ─▶ finding 2 ─┼─▶ synth ─▶ answer
//!                        └─▶ sub-agent 3 (own ctx) ─▶ finding 3 ─┘
//! ```
//! Nothing accumulates monotonically; raw pages live and die inside a sub-agent.

use std::sync::Arc;

use futures_util::stream::{self, StreamExt};
use serde::Deserialize;
use serde_json::{Map, Value};
use tokio::sync::{mpsc, Semaphore};
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::error::AppError;
use crate::ollama::ChatBackend;
use crate::openai::types::ChatMessage;
use crate::orchestrator::tools::{ToolExecutor, TurnContext};
use crate::orchestrator::turn::{select_schemas, stream_relay};
use crate::orchestrator::{ResearchPreset, TurnEvent};

/// Run one upstream `chat_once` while holding a permit from the shared
/// `upstream_sem`, so research's fanned-out calls obey the global concurrency
/// bound (NFR-O2) instead of riding on one whole-run permit. The permit is held
/// only for the duration of the call and released as soon as it returns.
///
/// Returns `None` on cancellation (either while queued for a permit or during
/// the call); callers treat that exactly like the cancel branch of a bare
/// `chat_once` select.
async fn chat_once_permit<B: ChatBackend>(
    backend: &B,
    sem: &Arc<Semaphore>,
    model: &str,
    messages: &[ChatMessage],
    tools: &[Value],
    options: &Map<String, Value>,
    cancel: &CancellationToken,
) -> Option<Result<ChatMessage, AppError>> {
    let _permit = tokio::select! {
        p = sem.clone().acquire_owned() => p.ok()?,
        _ = cancel.cancelled() => return None,
    };
    tokio::select! {
        r = backend.chat_once(model, messages, tools, options) => Some(r),
        _ = cancel.cancelled() => None,
    }
}

/// One sub-agent's distilled result: a short finding plus the URLs it used.
#[derive(Debug, Clone)]
struct Finding {
    sub_question: String,
    text: String,
    sources: Vec<String>,
}

/// Drive a full Deep Research turn. `messages` is the full conversation history
/// (XR-2); `base_model` is the upstream model the preset runs underneath.
#[allow(clippy::too_many_arguments)]
pub async fn run_research<B, T>(
    cfg: Arc<Config>,
    backend: B,
    tools: T,
    sem: Arc<Semaphore>,
    preset: &'static ResearchPreset,
    base_model: String,
    messages: Vec<ChatMessage>,
    options: Map<String, Value>,
    tx: mpsc::Sender<TurnEvent>,
    cancel: CancellationToken,
) where
    B: ChatBackend,
    T: ToolExecutor,
{
    // ---- Stage 1: PLAN -------------------------------------------------------
    let _ = tx
        .send(TurnEvent::Status("planning research…".into()))
        .await;

    let plan = match plan(
        &backend,
        &sem,
        &base_model,
        preset,
        &messages,
        &options,
        &cancel,
    )
    .await
    {
        Some(p) => p,
        None => return, // cancelled mid-plan
    };
    // `plan.sub_questions` is always non-empty: `parse_plan` injects a single
    // fallback question when the model returns nothing usable. The
    // `findings.is_empty()` guard below covers the otherwise-impossible case.

    // ---- Stage 2: RESEARCH (isolated sub-agents) -----------------------------
    let n = plan.sub_questions.len();
    let concurrency = preset.fanout.min(cfg.research_fanout_concurrency).max(1);
    tracing::info!(
        mode = preset.id,
        sub_questions = n,
        concurrency,
        "research plan ready; fanning out sub-agents"
    );
    let shared_ctx = TurnContext {
        research: true,
        ..Default::default()
    };
    // web_search-only, narrowed through the EXISTING select_schemas mechanism.
    let allow: Vec<String> = preset.tools.iter().map(|t| t.to_string()).collect();
    let schemas = select_schemas(tools.schemas(), &Some(allow));

    // Borrow everything the sub-agent closures share, once, so each `move`
    // closure captures a copy of the *reference* (not the owned value, which is
    // still needed for synthesis below).
    let backend_ref = &backend;
    let tools_ref = &tools;
    let sem_ref = &sem;
    let base_ref = base_model.as_str();
    let schemas_ref = schemas.as_slice();
    let options_ref = &options;
    let tx_ref = &tx;
    let cancel_ref = &cancel;

    // `concurrency` is a soft scheduling hint: it bounds how many sub-agents we
    // poll at once, but the real ceiling on concurrent upstream work is the
    // shared `upstream_sem` each sub-agent re-acquires per call (NFR-O2). With a
    // single GPU the two usually coincide; with headroom the semaphore wins.
    let findings: Vec<Finding> = stream::iter(plan.sub_questions.iter().cloned().enumerate())
        .map(|(i, sub_q)| {
            // Each sub-agent clones the context: the cache is SHARED (dedup
            // across siblings) but its messages vec is its own (isolation).
            let ctx = shared_ctx.clone();
            async move {
                let _ = tx_ref
                    .send(TurnEvent::Status(format!(
                        "researching {}/{n}: {}…",
                        i + 1,
                        truncate_label(&sub_q)
                    )))
                    .await;
                run_subagent(
                    backend_ref,
                    tools_ref,
                    sem_ref,
                    preset,
                    base_ref,
                    schemas_ref,
                    &ctx,
                    options_ref,
                    sub_q,
                    cancel_ref,
                )
                .await
            }
        })
        .buffer_unordered(concurrency)
        .collect()
        .await;

    if findings.is_empty() {
        // No sub-questions yielded a finding (should not happen — every
        // sub-agent returns one — but stay defensive).
        tracing::warn!("research produced no findings");
        let _ = tx
            .send(TurnEvent::Error("research produced no findings".into()))
            .await;
        return;
    }

    let total_sources: usize = findings.iter().map(|f| f.sources.len()).sum();
    tracing::info!(
        findings = findings.len(),
        total_sources,
        partial = cancel.is_cancelled(),
        "research gathered; synthesizing"
    );

    // ---- Stages 3 & 4: SYNTHESIZE (+ optional VERIFY) ------------------------
    // On a cancel observed after research, do a best-effort PARTIAL synthesis
    // over the findings already gathered (don't drop them). We run it under a
    // fresh, uncancelled token so the write actually completes; otherwise use
    // the live token so a later disconnect still aborts.
    let cancelled_mid = cancel.is_cancelled();
    let fresh = CancellationToken::new();
    let synth_cancel = if cancelled_mid { &fresh } else { &cancel };
    synthesize(
        &backend,
        &sem,
        &base_model,
        preset,
        &plan.brief,
        &findings,
        &options,
        &tx,
        synth_cancel,
        cancelled_mid,
    )
    .await;
}

/// Stage 1: produce a `{ brief, sub_questions }` plan. Returns `None` only on
/// cancellation; a parse failure falls back to a single sub-question = the
/// user's question (graceful, per NFR-O6).
async fn plan<B: ChatBackend>(
    backend: &B,
    sem: &Arc<Semaphore>,
    model: &str,
    preset: &ResearchPreset,
    history: &[ChatMessage],
    options: &Map<String, Value>,
    cancel: &CancellationToken,
) -> Option<Plan> {
    let user_q = latest_user_text(history);
    let mut msgs = vec![ChatMessage::system(preset.plan_prompt)];
    msgs.extend_from_slice(history);

    let resp = chat_once_permit(backend, sem, model, &msgs, &[], options, cancel).await?;

    let raw = resp.ok().and_then(message_text).unwrap_or_default();
    Some(parse_plan(&raw, &user_q, preset.fanout))
}

/// Stage 2: one isolated sub-agent. Owns a FRESH messages vec, runs a bounded
/// web_search-only loop, then compresses its transcript into a [`Finding`]. A
/// cancellation stops further searches but still distils what was gathered, so
/// the partial-synthesis path has findings to work with.
#[allow(clippy::too_many_arguments)]
async fn run_subagent<B: ChatBackend, T: ToolExecutor>(
    backend: &B,
    tools: &T,
    sem: &Arc<Semaphore>,
    preset: &ResearchPreset,
    model: &str,
    schemas: &[Value],
    ctx: &TurnContext,
    options: &Map<String, Value>,
    sub_question: String,
    cancel: &CancellationToken,
) -> Finding {
    // ISOLATION: a fresh context containing ONLY this sub-agent's system prompt
    // and its sub-question. No sibling findings, no brief, no raw pages from
    // other agents ever enter here.
    let mut msgs = vec![
        ChatMessage::system(preset.subagent_prompt),
        ChatMessage::user(&sub_question),
    ];

    // `searches_per_subq` is a SEARCH budget, not a round-trip budget: it counts
    // executed web_search tool calls, since one assistant turn may emit several
    // (or none). We decrement per executed search and stop once the budget is
    // spent, which in practice bounds the loop since each productive turn spends
    // at least one search.
    let mut searches_left = preset.searches_per_subq.max(1);
    // The search budget alone does NOT bound the loop: it only shrinks when a
    // call is literally named `web_search`, so a model that keeps hallucinating
    // other tool names would spin forever (unbounded `msgs` growth, GPU pinned).
    // Cap the assistant round-trips independently: enough for every budgeted
    // search to land on its own turn, with matching slack for wasted turns.
    let mut rounds_left = searches_left * 2 + 1;
    'agent: while searches_left > 0 && rounds_left > 0 {
        rounds_left -= 1;
        if cancel.is_cancelled() {
            break;
        }
        let resp =
            match chat_once_permit(backend, sem, model, &msgs, schemas, options, cancel).await {
                Some(Ok(m)) => m,
                Some(Err(e)) => {
                    // Backend error: distill whatever we have. Log it — otherwise
                    // a sub-agent failure is invisible (its finding just shrinks).
                    tracing::warn!(error = %e, "research sub-agent chat_once failed");
                    break;
                }
                None => break, // cancelled
            };
        match resp.tool_calls.clone().filter(|c| !c.is_empty()) {
            None => {
                msgs.push(resp);
                break; // sub-agent decided it is done searching
            }
            Some(calls) => {
                msgs.push(resp);
                for call in &calls {
                    if cancel.is_cancelled() || searches_left == 0 {
                        break 'agent;
                    }
                    let outcome = tools.execute(call, ctx, dummy_tx(), cancel.clone()).await;
                    msgs.push(outcome.message);
                    // Only an actual search spends budget; non-search tool calls
                    // (none today, but defensive) don't draw it down.
                    if call.function.name == "web_search" {
                        searches_left -= 1;
                    }
                }
            }
        }
    }

    // Compression: distill the transcript into a short finding + used URLs.
    // This runs even under cancellation (best-effort): a cancelled sub-agent
    // still contributes whatever it gathered, so the partial-synthesis path has
    // findings to work with rather than dropping the run entirely. It uses a
    // fresh, uncancelled token for the permit acquire so a mid-run cancel can't
    // strand the gathered work unwritten; the call itself stays cheap.
    let mut compress_msgs = msgs;
    compress_msgs.push(ChatMessage::system(preset.compress_prompt));
    let compress_cancel = CancellationToken::new();
    let raw = chat_once_permit(
        backend,
        sem,
        model,
        &compress_msgs,
        &[],
        options,
        &compress_cancel,
    )
    .await
    .and_then(Result::ok)
    .and_then(message_text)
    .unwrap_or_default();
    let (text, sources) = parse_compression(&raw);
    Finding {
        sub_question,
        text,
        sources,
    }
}

/// Stages 3 (+ optional 4): synthesize the final answer from brief + findings.
#[allow(clippy::too_many_arguments)]
async fn synthesize<B: ChatBackend>(
    backend: &B,
    sem: &Arc<Semaphore>,
    model: &str,
    preset: &ResearchPreset,
    brief: &str,
    findings: &[Finding],
    options: &Map<String, Value>,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
    partial: bool,
) {
    // Number sources globally (n → url) across all findings, deduped.
    let (sources, source_index) = number_sources(findings);
    let user_block = synthesis_user_block(brief, findings, &sources, &source_index);

    let msgs = vec![
        ChatMessage::system(preset.synth_prompt),
        ChatMessage::user(&user_block),
    ];

    if partial {
        let _ = tx
            .send(TurnEvent::Status("synthesizing partial answer…".into()))
            .await;
    } else {
        let _ = tx.send(TurnEvent::Status("synthesizing…".into())).await;
    }

    // No verify (or a partial/cancel synthesis): stream the answer live. The
    // streaming generation is one upstream call, so hold a permit for its whole
    // lifetime (acquired here, released when this scope ends).
    if !preset.verify || partial {
        let _permit = tokio::select! {
            p = sem.clone().acquire_owned() => match p {
                Ok(p) => p,
                Err(_) => return,
            },
            _ = cancel.cancelled() => return,
        };
        stream_relay(backend, model, &msgs, options, tx, cancel).await;
        return;
    }

    // Verify path: draft the answer non-streaming (this copy is never shown to
    // the user), then STREAM the citation-corrected rewrite so it arrives
    // token-by-token like an ordinary turn instead of landing as one block. The
    // verify call's output IS the final answer, so we relay it directly through
    // the shared streaming path; like the non-verify branch it is a single
    // upstream streaming call, and a backend failure surfaces as an Error event
    // rather than silently falling back to the unverified draft.
    let draft = match chat_once_permit(backend, sem, model, &msgs, &[], options, cancel).await {
        Some(Ok(m)) => message_text(m).unwrap_or_default(),
        Some(Err(e)) => {
            let _ = tx.send(TurnEvent::Error(e.to_string())).await;
            return;
        }
        None => return, // cancelled
    };

    let _ = tx
        .send(TurnEvent::Status("checking citations…".into()))
        .await;

    let verify_msgs = vec![
        ChatMessage::system(preset.verify_prompt),
        ChatMessage::user(verify_user_block(&sources, &draft)),
    ];
    let _permit = tokio::select! {
        p = sem.clone().acquire_owned() => match p {
            Ok(p) => p,
            Err(_) => return,
        },
        _ = cancel.cancelled() => return,
    };
    stream_relay(backend, model, &verify_msgs, options, tx, cancel).await;
}

/// The verify-pass user block: the valid numbered sources plus the draft to be
/// citation-corrected. Stage 4 streams the model's rewrite of this as the final
/// answer, dropping any `[n]` not backed by a listed source.
fn verify_user_block(sources: &[String], draft: &str) -> String {
    let valid = sources
        .iter()
        .enumerate()
        .map(|(i, url)| format!("[{}] {url}", i + 1))
        .collect::<Vec<_>>()
        .join("\n");
    format!("Valid sources:\n{valid}\n\n----- DRAFT ANSWER -----\n{draft}")
}

// ---- plan / compression parsing -------------------------------------------

#[derive(Debug)]
struct Plan {
    brief: String,
    sub_questions: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct RawPlan {
    #[serde(default)]
    brief: String,
    #[serde(default)]
    sub_questions: Vec<String>,
}

/// Parse the planner's JSON defensively. On any failure, fall back to a single
/// sub-question equal to the user's question with the question as the brief.
fn parse_plan(raw: &str, user_question: &str, fanout: usize) -> Plan {
    let fallback = || Plan {
        brief: user_question.to_string(),
        sub_questions: vec![user_question.to_string()],
    };
    let Some(json) = extract_json_object(raw) else {
        return fallback();
    };
    let Ok(parsed) = serde_json::from_str::<RawPlan>(&json) else {
        return fallback();
    };
    let mut subs: Vec<String> = parsed
        .sub_questions
        .into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if subs.is_empty() {
        return fallback();
    }
    subs.truncate(fanout.max(1)); // cap at the preset's fan-out
    let brief = if parsed.brief.trim().is_empty() {
        user_question.to_string()
    } else {
        parsed.brief
    };
    Plan {
        brief,
        sub_questions: subs,
    }
}

#[derive(Debug, Deserialize)]
struct RawCompression {
    #[serde(default)]
    finding: String,
    #[serde(default)]
    sources: Vec<String>,
}

/// Parse a compression result into `(finding_text, sources)`. On parse failure
/// we keep the raw text as the finding with no sources (graceful — the writer
/// still gets the prose, just uncited from this sub-agent).
fn parse_compression(raw: &str) -> (String, Vec<String>) {
    if let Some(json) = extract_json_object(raw) {
        if let Ok(parsed) = serde_json::from_str::<RawCompression>(&json) {
            let sources = parsed
                .sources
                .into_iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            let finding = if parsed.finding.trim().is_empty() {
                raw.trim().to_string()
            } else {
                parsed.finding
            };
            return (finding, sources);
        }
    }
    (raw.trim().to_string(), Vec::new())
}

/// Pull the first balanced `{…}` JSON object out of a string, tolerating
/// surrounding prose or ```json code fences. Returns `None` if none is found.
fn extract_json_object(s: &str) -> Option<String> {
    let start = s.find('{')?;
    let bytes = s.as_bytes();
    let mut depth = 0usize;
    let mut in_str = false;
    let mut escaped = false;
    for (i, &b) in bytes.iter().enumerate().skip(start) {
        if in_str {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_str = false;
            }
            continue;
        }
        match b {
            b'"' => in_str = true,
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(s[start..=i].to_string());
                }
            }
            _ => {}
        }
    }
    None
}

// ---- source numbering & synthesis assembly --------------------------------

/// Build the global numbered source list (n → url) deduped across findings,
/// plus a map from url → its 1-based number, in first-seen order.
fn number_sources(findings: &[Finding]) -> (Vec<String>, std::collections::HashMap<String, usize>) {
    let mut sources = Vec::new();
    let mut index = std::collections::HashMap::new();
    for f in findings {
        for url in &f.sources {
            if !index.contains_key(url) {
                sources.push(url.clone());
                index.insert(url.clone(), sources.len());
            }
        }
    }
    (sources, index)
}

/// Assemble the synthesis user block: brief + each finding (with the source
/// numbers it maps to) + the numbered Sources list the writer must cite against.
fn synthesis_user_block(
    brief: &str,
    findings: &[Finding],
    sources: &[String],
    index: &std::collections::HashMap<String, usize>,
) -> String {
    let mut out = format!("Brief:\n{brief}\n\nFindings:\n");
    for (i, f) in findings.iter().enumerate() {
        let nums: Vec<String> = f
            .sources
            .iter()
            .filter_map(|u| index.get(u))
            .map(|n| format!("[{n}]"))
            .collect();
        out.push_str(&format!(
            "\n{}. Sub-question: {}\n   Finding: {}\n   Cite as: {}\n",
            i + 1,
            f.sub_question,
            f.text,
            if nums.is_empty() {
                "(no sources)".to_string()
            } else {
                nums.join(" ")
            }
        ));
    }
    out.push_str("\nSources (cite by number):\n");
    for (i, url) in sources.iter().enumerate() {
        out.push_str(&format!("[{}] {url}\n", i + 1));
    }
    out
}

// ---- small message helpers ------------------------------------------------

/// Concatenated text content of a message (images dropped — stages only reason
/// over text). `None`-content messages yield an empty string.
fn message_text(m: ChatMessage) -> Option<String> {
    m.content
        .map(|c| c.into_text_and_images().0.unwrap_or_default())
}

/// The text of the most recent `user` message, used as the planner's fallback
/// question. Empty if there is none.
fn latest_user_text(history: &[ChatMessage]) -> String {
    history
        .iter()
        .rev()
        .find(|m| m.role == "user")
        .and_then(|m| m.content.clone())
        .map(|c| c.into_text_and_images().0.unwrap_or_default())
        .unwrap_or_default()
}

/// Truncate a sub-question for an `x_status` label so a heartbeat stays terse.
fn truncate_label(s: &str) -> String {
    const MAX: usize = 80;
    if s.chars().count() <= MAX {
        return s.to_string();
    }
    let truncated: String = s.chars().take(MAX).collect();
    format!("{truncated}…")
}

/// A drop-on-the-floor sender for sub-agent tool progress: per-search status
/// from inside an isolated worker would be noisy, and the orchestrator already
/// emits per-sub-question heartbeats. Tool execution still needs *a* sender.
fn dummy_tx() -> mpsc::Sender<TurnEvent> {
    // Capacity 1 with an immediately-dropped receiver: sends fail silently,
    // which the tool layer tolerates (it never treats a send error as fatal).
    let (tx, _rx) = mpsc::channel(1);
    tx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_plan_reads_brief_and_subquestions() {
        let raw = r#"{"brief": "compare X and Y", "sub_questions": ["what is X", "what is Y", "how do they differ"]}"#;
        let p = parse_plan(raw, "fallback q", 5);
        assert_eq!(p.brief, "compare X and Y");
        assert_eq!(p.sub_questions.len(), 3);
    }

    #[test]
    fn parse_plan_caps_at_fanout() {
        let raw = r#"{"brief":"b","sub_questions":["a","b","c","d","e","f"]}"#;
        let p = parse_plan(raw, "q", 3);
        assert_eq!(p.sub_questions.len(), 3);
    }

    #[test]
    fn parse_plan_tolerates_code_fence_and_prose() {
        let raw = "Here is the plan:\n```json\n{\"brief\":\"b\",\"sub_questions\":[\"only one\"]}\n```\nDone.";
        let p = parse_plan(raw, "q", 5);
        assert_eq!(p.brief, "b");
        assert_eq!(p.sub_questions, vec!["only one".to_string()]);
    }

    #[test]
    fn parse_plan_prose_falls_back_to_single_subquestion() {
        let p = parse_plan(
            "I think we should look into several things.",
            "the user question",
            5,
        );
        assert_eq!(p.brief, "the user question");
        assert_eq!(p.sub_questions, vec!["the user question".to_string()]);
    }

    #[test]
    fn parse_compression_reads_finding_and_sources() {
        let raw = r#"{"finding":"X is a thing","sources":["https://a","https://b"]}"#;
        let (text, sources) = parse_compression(raw);
        assert_eq!(text, "X is a thing");
        assert_eq!(
            sources,
            vec!["https://a".to_string(), "https://b".to_string()]
        );
    }

    #[test]
    fn parse_compression_prose_keeps_raw_text_no_sources() {
        let (text, sources) = parse_compression("Just some prose with no JSON.");
        assert_eq!(text, "Just some prose with no JSON.");
        assert!(sources.is_empty());
    }

    #[test]
    fn number_sources_dedups_across_findings() {
        let findings = vec![
            Finding {
                sub_question: "q1".into(),
                text: "f1".into(),
                sources: vec!["https://a".into(), "https://b".into()],
            },
            Finding {
                sub_question: "q2".into(),
                text: "f2".into(),
                // https://a is a repeat; https://c is new.
                sources: vec!["https://a".into(), "https://c".into()],
            },
        ];
        let (sources, index) = number_sources(&findings);
        assert_eq!(sources, vec!["https://a", "https://b", "https://c"]);
        assert_eq!(index["https://a"], 1);
        assert_eq!(index["https://c"], 3);
    }

    #[test]
    fn extract_json_object_handles_nested_and_strings() {
        let s = r#"prefix {"a": {"b": 1}, "c": "}"} suffix"#;
        let got = extract_json_object(s).unwrap();
        assert_eq!(got, r#"{"a": {"b": 1}, "c": "}"}"#);
    }

    // ---- engine integration (scripted backend + tools, no network) ----------

    use crate::ollama::{DeltaStream, StreamDelta};
    use crate::openai::types::{FunctionCall, MessageContent, RawArguments, ToolCall};
    use crate::orchestrator::tools::ToolOutcome;
    use std::sync::Mutex;

    const PLAN_MARK: &str = "planning step";
    const SUBAGENT_MARK: &str = "investigating ONE sub-question";
    const COMPRESS_MARK: &str = "Summarize your research";
    const SYNTH_MARK: &str = "writer of a deep-research";
    const VERIFY_MARK: &str = "citation-checking step";

    /// A stage-routing scripted backend. It inspects the system prompt to decide
    /// which canned reply to give, and records every message set passed to
    /// `chat_once` so tests can assert what each stage *saw* (context isolation).
    #[derive(Clone)]
    struct Engine {
        plan_reply: Arc<String>,
        compress_reply: Arc<String>, // shared by every sub-agent
        verify_reply: Arc<String>,
        seen: Arc<Mutex<Vec<Vec<ChatMessage>>>>,
        subagent_should_search: Arc<Mutex<bool>>,
        /// Optional gate: when set, the compress stage signals `reached` and
        /// waits on `resume` so a test can deterministically cancel *between*
        /// research and synthesis.
        gate: Option<(Arc<tokio::sync::Notify>, Arc<tokio::sync::Notify>)>,
    }

    impl Engine {
        fn new(plan: &str, compress: &str, verify: &str) -> Self {
            Engine {
                plan_reply: Arc::new(plan.into()),
                compress_reply: Arc::new(compress.into()),
                verify_reply: Arc::new(verify.into()),
                seen: Arc::new(Mutex::new(vec![])),
                subagent_should_search: Arc::new(Mutex::new(true)),
                gate: None,
            }
        }

        fn system_text(messages: &[ChatMessage]) -> String {
            messages
                .iter()
                .filter(|m| m.role == "system")
                .filter_map(|m| message_text(m.clone()))
                .collect::<Vec<_>>()
                .join("\n")
        }
    }

    fn ass(content: &str) -> ChatMessage {
        ChatMessage {
            role: "assistant".into(),
            content: Some(MessageContent::Text(content.into())),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    fn ass_calling(tool: &str) -> ChatMessage {
        ChatMessage {
            role: "assistant".into(),
            content: None,
            tool_calls: Some(vec![ToolCall {
                id: Some("c1".into()),
                kind: "function".into(),
                function: FunctionCall {
                    name: tool.into(),
                    arguments: RawArguments::Obj(serde_json::json!({"query":"x"})),
                },
            }]),
            tool_call_id: None,
            name: None,
        }
    }

    impl ChatBackend for Engine {
        async fn chat_once(
            &self,
            _model: &str,
            messages: &[ChatMessage],
            _tools: &[Value],
            _options: &Map<String, Value>,
        ) -> Result<ChatMessage, crate::error::AppError> {
            self.seen.lock().unwrap().push(messages.to_vec());
            let sys = Self::system_text(messages);
            if sys.contains(PLAN_MARK) {
                return Ok(ass(&self.plan_reply));
            }
            if sys.contains(COMPRESS_MARK) {
                if let Some((reached, resume)) = &self.gate {
                    reached.notify_one();
                    resume.notified().await;
                }
                return Ok(ass(&self.compress_reply));
            }
            if sys.contains(VERIFY_MARK) {
                return Ok(ass(&self.verify_reply));
            }
            if sys.contains(SYNTH_MARK) {
                // Non-streaming synthesis draft (verify path).
                return Ok(ass("DRAFT [1] [2] [9]"));
            }
            if sys.contains(SUBAGENT_MARK) {
                // First sub-agent turn searches once; subsequent turns answer.
                let mut flag = self.subagent_should_search.lock().unwrap();
                if *flag {
                    *flag = false;
                    return Ok(ass_calling("web_search"));
                }
                return Ok(ass("I have enough to answer."));
            }
            Ok(ass("unrouted"))
        }

        async fn chat_stream(
            &self,
            _model: &str,
            messages: &[ChatMessage],
            _options: &Map<String, Value>,
        ) -> Result<DeltaStream, crate::error::AppError> {
            // Record the streamed context too (the verify pass now streams), so
            // isolation/verify assertions can inspect what each lead stage saw.
            self.seen.lock().unwrap().push(messages.to_vec());
            // The verify pass streams its corrected answer; the non-verify
            // synthesis streams a fixed answer. Route by system prompt, mirroring
            // chat_once.
            let reply = if Self::system_text(messages).contains(VERIFY_MARK) {
                (*self.verify_reply).clone()
            } else {
                "SYNTH ANSWER".to_string()
            };
            let s = async_stream::stream! {
                yield Ok(StreamDelta::content(reply, true, Some("stop".into())));
            };
            Ok(Box::pin(s))
        }
    }

    /// A web_search tool that returns RAW page text (the thing the lead must
    /// NEVER see) and records that it ran.
    #[derive(Clone)]
    struct RawPageTool {
        executed: Arc<Mutex<Vec<String>>>,
    }

    const RAW_PAGE_SENTINEL: &str = "RAW_PAGE_BODY_TOP_SECRET";

    impl ToolExecutor for RawPageTool {
        fn schemas(&self) -> Vec<Value> {
            vec![
                serde_json::json!({"type":"function","function":{"name":"web_search"}}),
                serde_json::json!({"type":"function","function":{"name":"image_generation"}}),
            ]
        }
        async fn execute(
            &self,
            call: &ToolCall,
            _ctx: &TurnContext,
            _tx: mpsc::Sender<TurnEvent>,
            _cancel: CancellationToken,
        ) -> ToolOutcome {
            self.executed
                .lock()
                .unwrap()
                .push(call.function.name.clone());
            ToolOutcome {
                message: ChatMessage::tool_result(
                    "c1",
                    "web_search",
                    format!("results: {RAW_PAGE_SENTINEL} https://src.example/a"),
                ),
                append_to_answer: None,
            }
        }
    }

    async fn drain(mut rx: mpsc::Receiver<TurnEvent>) -> Vec<TurnEvent> {
        let mut out = Vec::new();
        while let Some(e) = rx.recv().await {
            out.push(e);
        }
        out
    }

    fn tokens(events: &[TurnEvent]) -> String {
        events
            .iter()
            .filter_map(|e| match e {
                TurnEvent::Token(t) => Some(t.clone()),
                _ => None,
            })
            .collect()
    }

    fn cfg() -> Arc<Config> {
        Arc::new(crate::config::tests_support::minimal())
    }

    fn deep() -> &'static ResearchPreset {
        cfg().presets().resolve_model("m:deep-research").1.unwrap()
    }

    fn quick() -> &'static ResearchPreset {
        cfg().presets().resolve_model("m:quick-research").1.unwrap()
    }

    fn history(q: &str) -> Vec<ChatMessage> {
        vec![ChatMessage::user(q)]
    }

    #[tokio::test]
    async fn plan_with_n_subquestions_spawns_n_subagents() {
        // Plan returns 3 sub-questions → 3 isolated sub-agents → 3 compressions.
        let plan = r#"{"brief":"compare","sub_questions":["q1","q2","q3"]}"#;
        let compress = r#"{"finding":"f","sources":["https://src.example/a"]}"#;
        let backend = Engine::new(plan, compress, "FINAL");
        let tools = RawPageTool {
            executed: Arc::new(Mutex::new(vec![])),
        };
        let (tx, rx) = mpsc::channel(256);
        run_research(
            cfg(),
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(4)),
            quick(), // quick: verify=false, fanout=2 → capped to 2 sub-qs
            "m".into(),
            history("compare q"),
            Map::new(),
            tx,
            CancellationToken::new(),
        )
        .await;
        let _ = drain(rx).await;
        // quick fanout is 2, so the 3-item plan is capped to 2 sub-agents.
        let subagent_systems = backend
            .seen
            .lock()
            .unwrap()
            .iter()
            .filter(|m| Engine::system_text(m).contains(SUBAGENT_MARK))
            .count();
        // Each sub-agent does: search turn + answer turn + compress turn = 3
        // chat_once with the sub-agent system present (compress reuses the
        // transcript, so its system_text still contains the sub-agent prompt).
        assert!(subagent_systems >= 2, "expected ≥2 sub-agent contexts");
    }

    #[tokio::test]
    async fn prose_plan_falls_back_to_single_subagent() {
        let backend = Engine::new(
            "I'm not going to produce JSON, sorry.",
            r#"{"finding":"f","sources":[]}"#,
            "FINAL",
        );
        let tools = RawPageTool {
            executed: Arc::new(Mutex::new(vec![])),
        };
        let (tx, rx) = mpsc::channel(256);
        run_research(
            cfg(),
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(4)),
            quick(),
            "m".into(),
            history("the only question"),
            Map::new(),
            tx,
            CancellationToken::new(),
        )
        .await;
        let _ = drain(rx).await;
        // Exactly one sub-agent, and it was handed the fallback question.
        let seen = backend.seen.lock().unwrap();
        let subagent_users: Vec<String> = seen
            .iter()
            .filter(|m| Engine::system_text(m).contains(SUBAGENT_MARK))
            .filter_map(|m| {
                m.iter()
                    .find(|x| x.role == "user")
                    .and_then(|x| message_text(x.clone()))
            })
            .collect();
        assert!(subagent_users.iter().any(|u| u == "the only question"));
    }

    #[tokio::test]
    async fn context_isolation_lead_never_sees_raw_pages_or_siblings() {
        // Two sub-agents; each fetches RAW_PAGE_SENTINEL via web_search. The
        // synthesis (and verify) contexts must contain neither the raw page text
        // nor the other sub-agent's transcript.
        let plan = r#"{"brief":"B","sub_questions":["alpha question","beta question"]}"#;
        let compress = r#"{"finding":"clean finding","sources":["https://src.example/a"]}"#;
        let backend = Engine::new(plan, compress, "FINAL ANSWER [1]");
        let tools = RawPageTool {
            executed: Arc::new(Mutex::new(vec![])),
        };
        let (tx, rx) = mpsc::channel(256);
        run_research(
            cfg(),
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(4)),
            deep(), // verify=true so the synth+verify contexts are exercised
            "m".into(),
            history("compare alpha and beta"),
            Map::new(),
            tx,
            CancellationToken::new(),
        )
        .await;
        let _ = drain(rx).await;

        let seen = backend.seen.lock().unwrap();
        // Sub-agent contexts ARE allowed to see raw pages (that's their job).
        // Synthesis + verify contexts must NOT.
        for msgs in seen.iter() {
            let sys = Engine::system_text(msgs);
            let is_lead = sys.contains(SYNTH_MARK) || sys.contains(VERIFY_MARK);
            if !is_lead {
                continue;
            }
            // Examine the DATA the lead was handed (its non-system messages),
            // not the wording of its own system prompt.
            let blob = msgs
                .iter()
                .filter(|m| m.role != "system")
                .filter_map(|m| message_text(m.clone()))
                .collect::<String>();
            assert!(
                !blob.contains(RAW_PAGE_SENTINEL),
                "lead stage leaked raw page text"
            );
            // The lead sees the brief + findings, not sibling sub-agent prompts.
            assert!(
                !blob.contains(SUBAGENT_MARK),
                "lead stage leaked a sub-agent transcript: {blob}"
            );
        }
        // And a sub-agent context must NOT contain the other sub-agent's
        // sub-question (siblings are isolated from each other).
        let alpha_ctx = seen.iter().find(|m| {
            Engine::system_text(m).contains(SUBAGENT_MARK)
                && m.iter().any(|x| {
                    message_text(x.clone())
                        .map(|t| t.contains("alpha question"))
                        .unwrap_or(false)
                })
        });
        if let Some(ctx) = alpha_ctx {
            let blob = ctx
                .iter()
                .filter_map(|m| message_text(m.clone()))
                .collect::<String>();
            assert!(
                !blob.contains("beta question"),
                "sub-agent saw a sibling's sub-question"
            );
        }
    }

    #[tokio::test]
    async fn verify_pass_drops_unmapped_citation() {
        // Plan→2 findings yielding sources [1] and [2]. The synthesis DRAFT (from
        // the scripted backend) emits "[1] [2] [9]"; [9] has no source, so the
        // verify pass (driven by VERIFY_PROMPT) must drop it. We assert by giving
        // the verify stage a reply that proves it received the valid-source list
        // and dropping the bogus marker ourselves in the canned reply — and by
        // checking the verify stage's INPUT only lists sources 1 and 2.
        let plan = r#"{"brief":"B","sub_questions":["q1","q2"]}"#;
        let compress = r#"{"finding":"f","sources":["https://src.example/a"]}"#;
        // The verify reply is the corrected answer (a real model would drop [9]).
        let backend = Engine::new(plan, compress, "FINAL [1]");
        let tools = RawPageTool {
            executed: Arc::new(Mutex::new(vec![])),
        };
        let (tx, rx) = mpsc::channel(256);
        run_research(
            cfg(),
            backend.clone(),
            tools,
            Arc::new(Semaphore::new(4)),
            deep(),
            "m".into(),
            history("q"),
            Map::new(),
            tx,
            CancellationToken::new(),
        )
        .await;
        let events = drain(rx).await;
        // The corrected answer (verify reply) is what reaches the client.
        assert_eq!(tokens(&events), "FINAL [1]");
        // The verify stage's input listed only the VALID sources (no [9]).
        let seen = backend.seen.lock().unwrap();
        let verify_ctx = seen
            .iter()
            .find(|m| Engine::system_text(m).contains(VERIFY_MARK))
            .expect("verify stage ran");
        let blob = verify_ctx
            .iter()
            .filter_map(|m| message_text(m.clone()))
            .collect::<String>();
        // It WAS handed the draft containing the bogus [9] to correct.
        assert!(blob.contains("DRAFT [1] [2] [9]"));
        // The VALID-sources portion (before the draft) lists only real sources —
        // [9] is never presented as a valid citation for the model to keep.
        let valid_block = blob.split("DRAFT ANSWER").next().unwrap();
        assert!(valid_block.contains("[1] https://src.example/a"));
        assert!(
            !valid_block.contains("[9]"),
            "verify must not be told [9] is valid"
        );
    }

    #[tokio::test]
    async fn subagent_loop_terminates_when_model_never_calls_web_search() {
        // A model that keeps hallucinating tool names other than `web_search`
        // never spends the search budget; the independent round-trip cap must
        // still terminate the loop (and the compression call still runs).
        #[derive(Clone)]
        struct BogusCaller {
            calls: Arc<Mutex<usize>>,
        }

        impl ChatBackend for BogusCaller {
            async fn chat_once(
                &self,
                _model: &str,
                messages: &[ChatMessage],
                _tools: &[Value],
                _options: &Map<String, Value>,
            ) -> Result<ChatMessage, crate::error::AppError> {
                *self.calls.lock().unwrap() += 1;
                if Engine::system_text(messages).contains(COMPRESS_MARK) {
                    return Ok(ass("nothing conclusive"));
                }
                Ok(ass_calling("not_a_real_tool"))
            }

            async fn chat_stream(
                &self,
                _model: &str,
                _messages: &[ChatMessage],
                _options: &Map<String, Value>,
            ) -> Result<DeltaStream, crate::error::AppError> {
                Err(crate::error::AppError::UpstreamError("unused".into()))
            }
        }

        let backend = BogusCaller {
            calls: Arc::new(Mutex::new(0)),
        };
        let tools = RawPageTool {
            executed: Arc::new(Mutex::new(vec![])),
        };
        let preset = quick();
        let finding = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            run_subagent(
                &backend,
                &tools,
                &Arc::new(Semaphore::new(2)),
                preset,
                "m",
                &[],
                &TurnContext::default(),
                &Map::new(),
                "q".into(),
                &CancellationToken::new(),
            ),
        )
        .await
        .expect("sub-agent loop must terminate without spending the search budget");
        assert_eq!(finding.sub_question, "q");

        // Bounded round-trips: at most `budget * 2 + 1` agent turns plus the
        // one compression call.
        let cap = preset.searches_per_subq.max(1) * 2 + 1;
        assert!(
            *backend.calls.lock().unwrap() <= cap + 1,
            "expected at most {} upstream calls, saw {}",
            cap + 1,
            *backend.calls.lock().unwrap()
        );
    }

    #[tokio::test]
    async fn cancel_mid_research_still_streams_partial_answer() {
        // One finding lands, then we cancel before synthesis. A best-effort
        // partial synthesis must still stream an answer rather than dropping it.
        // The compress gate lets us cancel deterministically AFTER the finding is
        // gathered but BEFORE synthesis begins.
        let plan = r#"{"brief":"B","sub_questions":["q1"]}"#;
        let compress = r#"{"finding":"partial finding","sources":["https://src.example/a"]}"#;
        let mut backend = Engine::new(plan, compress, "FINAL");
        let reached = Arc::new(tokio::sync::Notify::new());
        let resume = Arc::new(tokio::sync::Notify::new());
        backend.gate = Some((reached.clone(), resume.clone()));
        let tools = RawPageTool {
            executed: Arc::new(Mutex::new(vec![])),
        };
        let (tx, rx) = mpsc::channel(256);
        let cancel = CancellationToken::new();

        let cancel_for_task = cancel.clone();
        let handle = tokio::spawn(async move {
            run_research(
                cfg(),
                backend,
                tools,
                Arc::new(Semaphore::new(4)),
                quick(),
                "m".into(),
                history("q"),
                Map::new(),
                tx,
                cancel_for_task,
            )
            .await;
        });

        // Wait until the (only) sub-agent reaches its compression call, then
        // cancel and let it proceed: research finishes with one finding, and the
        // synthesis stage must observe the cancel and do a partial synthesis.
        reached.notified().await;
        cancel.cancel();
        resume.notify_one();

        let events = drain(rx).await;
        handle.await.unwrap();

        // Despite the cancel, the partial synthesis streamed an answer.
        assert!(
            events
                .iter()
                .any(|e| matches!(e, TurnEvent::Status(s) if s.contains("partial"))),
            "expected a partial-synthesis heartbeat"
        );
        assert_eq!(tokens(&events), "SYNTH ANSWER");
    }
}
