//! Web search tool backed by the Brave Search API (FR-O4 / NFR-O8).
//!
//! **Snippet-first:** by default we return result titles + descriptions as the
//! tool output and never fetch result pages — snippets answer a large fraction
//! of queries and this keeps search turns ~1-2s. Optional page fetching is
//! gated behind the `page_fetch` cargo feature *and* the `SEARCH_FETCH_PAGES`
//! runtime flag, is bounded-concurrent with a hard per-URL timeout, and drops
//! stragglers. We never embed/chunk/RAG fresh results.

use schemars::JsonSchema;
use serde::Deserialize;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;

const SEARCH_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Deserialize, JsonSchema)]
pub struct WebSearchArgs {
    /// The search query.
    pub query: String,
    /// Maximum number of results to consider (optional).
    #[serde(default)]
    pub count: Option<u8>,
}

pub fn schema() -> serde_json::Value {
    let params = serde_json::to_value(schemars::schema_for!(WebSearchArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "web_search",
        "Search the web for current information. Returns titles and snippets.",
        params,
    )
}

#[derive(Debug, Deserialize)]
struct BraveResponse {
    #[serde(default)]
    web: Option<BraveWeb>,
}

#[derive(Debug, Deserialize)]
struct BraveWeb {
    #[serde(default)]
    results: Vec<BraveResult>,
}

#[derive(Debug, Deserialize)]
struct BraveResult {
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    description: String,
}

pub async fn run(
    cfg: &Config,
    http: &reqwest::Client,
    call: &ToolCall,
    call_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: WebSearchArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => {
            return error_outcome(call_id, format!("invalid arguments: {e}"));
        }
    };

    let _ = tx
        .send(TurnEvent::Status("searching the web…".into()))
        .await;

    let result = tokio::select! {
        r = do_search(cfg, http, &args) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok(text) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "web_search", text),
            append_to_answer: None,
        },
        Err(detail) => {
            let _ = tx
                .send(TurnEvent::Status("web search unavailable".into()))
                .await;
            error_outcome(call_id, detail)
        }
    }
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "web_search",
            format!("web_search failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

async fn do_search(
    cfg: &Config,
    http: &reqwest::Client,
    args: &WebSearchArgs,
) -> Result<String, String> {
    let token = cfg
        .brave_token
        .as_deref()
        .ok_or_else(|| "no Brave API key configured".to_string())?;

    let count = args
        .count
        .map(|c| c as usize)
        .unwrap_or(cfg.search_max_results)
        .clamp(1, 20);

    let url = cfg
        .brave_base
        .join("/res/v1/web/search")
        .map_err(|e| e.to_string())?;

    let resp = http
        .get(url)
        .query(&[("q", args.query.as_str()), ("count", &count.to_string())])
        .header("Accept", "application/json")
        .header("Accept-Encoding", "gzip")
        .header("X-Subscription-Token", token)
        .timeout(SEARCH_REQUEST_TIMEOUT)
        .send()
        .await
        .map_err(|e| format!("backend unreachable: {e}"))?;

    if !resp.status().is_success() {
        return Err(format!("Brave returned {}", resp.status()));
    }

    let body: BraveResponse = resp.json().await.map_err(|e| e.to_string())?;
    let results = body.web.map(|w| w.results).unwrap_or_default();

    if results.is_empty() {
        return Ok(format!("No web results for \"{}\".", args.query));
    }

    let results: Vec<BraveResult> = results.into_iter().take(count).collect();

    #[cfg(feature = "page_fetch")]
    let extracts = if cfg.search_fetch_pages {
        fetch_pages(cfg, http, &results).await
    } else {
        Vec::new()
    };
    #[cfg(not(feature = "page_fetch"))]
    let extracts: Vec<Option<String>> = Vec::new();

    Ok(format_snippets(
        &args.query,
        &results,
        &extracts,
        cfg.search_context_char_cap,
    ))
}

/// Build a compact, context-capped result list. `extracts[i]` (if present) is an
/// optional page extract appended under result `i`.
fn format_snippets(
    query: &str,
    results: &[BraveResult],
    extracts: &[Option<String>],
    cap: usize,
) -> String {
    let mut out = format!("Web search results for \"{query}\":\n\n");
    for (i, r) in results.iter().enumerate() {
        let mut entry = format!("{}. {} — {} ({})\n", i + 1, r.title, r.description, r.url);
        if let Some(Some(extract)) = extracts.get(i) {
            entry.push_str("   ");
            entry.push_str(extract);
            entry.push('\n');
        }
        if out.len() + entry.len() > cap {
            break;
        }
        out.push_str(&entry);
    }
    truncate_at_char_boundary(&mut out, cap);
    out
}

fn truncate_at_char_boundary(out: &mut String, cap: usize) {
    if out.len() <= cap {
        return;
    }

    let mut end = cap;
    while !out.is_char_boundary(end) {
        end -= 1;
    }
    out.truncate(end);
}

#[cfg(feature = "page_fetch")]
async fn fetch_pages(
    cfg: &Config,
    http: &reqwest::Client,
    results: &[BraveResult],
) -> Vec<Option<String>> {
    use futures_util::stream::{self, StreamExt};

    let timeout = Duration::from_millis(cfg.search_fetch_timeout_ms);
    let per_extract_cap = (cfg.search_context_char_cap / results.len().max(1)).max(200);

    // Map over owned `String`s (not `&BraveResult`) and move an owned client
    // clone (cheap — `reqwest::Client` is `Arc` inside) into each future, so the
    // bounded-concurrency stream carries no borrow lifetime (avoids an HRTB error).
    let urls: Vec<String> = results.iter().map(|r| r.url.clone()).collect();
    let futures = urls.into_iter().map(|url| {
        let http = http.clone();
        async move {
            match tokio::time::timeout(timeout, http.get(&url).send()).await {
                Ok(Ok(resp)) => match tokio::time::timeout(timeout, resp.text()).await {
                    Ok(Ok(html)) => Some(html_to_text(&html, per_extract_cap)),
                    _ => None,
                },
                _ => None, // timed out or errored — drop this straggler
            }
        }
    });

    stream::iter(futures)
        .buffer_unordered(cfg.search_fetch_concurrency)
        .collect()
        .await
}

/// Minimal HTML-to-text: strip tags and collapse whitespace, then truncate.
#[cfg(feature = "page_fetch")]
fn html_to_text(html: &str, cap: usize) -> String {
    let mut text = String::new();
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => text.push(c),
            _ => {}
        }
    }
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed.chars().take(cap).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(title: &str, desc: &str, url: &str) -> BraveResult {
        BraveResult {
            title: title.into(),
            description: desc.into(),
            url: url.into(),
        }
    }

    #[test]
    fn snippets_are_numbered_and_capped() {
        let results = vec![
            r("Rust", "A language", "https://rust-lang.org"),
            r("Tokio", "Async runtime", "https://tokio.rs"),
        ];
        let out = format_snippets("rust", &results, &[], 4000);
        assert!(out.contains("1. Rust — A language (https://rust-lang.org)"));
        assert!(out.contains("2. Tokio — Async runtime (https://tokio.rs)"));
    }

    #[test]
    fn context_cap_is_respected() {
        let results = vec![r("T", "long description here", "https://x")];
        let out = format_snippets("q", &results, &[], 20);
        assert!(out.len() <= 20);
    }

    #[test]
    fn context_cap_does_not_split_utf8_query() {
        let query = "\u{1f600}";
        let cap = "Web search results for \"".len() + 1;
        let out = format_snippets(query, &[], &[], cap);
        assert!(out.len() <= cap);
    }

    #[test]
    fn schema_is_a_function_tool() {
        let s = schema();
        assert_eq!(s["type"], "function");
        assert_eq!(s["function"]["name"], "web_search");
        assert!(s["function"]["parameters"]["properties"]["query"].is_object());
    }
}
