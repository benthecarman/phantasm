//! Web search tool backed by the Brave Search API (FR-O4 / NFR-O8).
//!
//! **Snippet-first:** by default we return result titles + descriptions as the
//! tool output and never fetch result pages — snippets answer a large fraction
//! of queries and this keeps search turns ~1-2s. Full-page fetching is the
//! `depth="thorough"` path, chosen by the *model* per query (not a global
//! switch): it's only offered when the `SEARCH_FETCH_PAGES` runtime gate permits
//! it. Even then the model defaults to `quick`, so a simple "price of bitcoin"
//! query stays fast and only research/comparison queries pay the fetch cost.
//! Fetching is bounded-concurrent with a hard per-URL timeout and drops
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

/// How deep a search goes. `Quick` returns Brave's titles + snippets and is the
/// default; `Thorough` additionally fetches and extracts the full result pages.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum SearchDepth {
    /// Titles + snippets only. Fast — use for facts, prices, definitions, and
    /// anything a one-line answer covers.
    #[default]
    Quick,
    /// Also fetch and extract full page text. Slower — use for comparisons,
    /// multi-source synthesis, or when snippets are clearly insufficient.
    Thorough,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct WebSearchArgs {
    /// The search query.
    pub query: String,
    /// Maximum number of results to consider (optional).
    #[serde(default)]
    pub count: Option<u8>,
    /// Search depth (optional; defaults to "quick"). Only set "thorough" when
    /// snippets won't suffice — it is noticeably slower.
    #[serde(default)]
    pub depth: SearchDepth,
}

/// Build the tool schema. When `thorough` is false (feature off or runtime gate
/// disabled) the `depth` parameter is omitted entirely, so the model is never
/// told about a path it can't take and always gets the fast snippet behavior.
pub fn schema(thorough: bool) -> serde_json::Value {
    let mut params = serde_json::to_value(schemars::schema_for!(WebSearchArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    if !thorough {
        if let Some(props) = params.get_mut("properties").and_then(|p| p.as_object_mut()) {
            props.remove("depth");
        }
    }
    let description = if thorough {
        "Search the web for current information. Returns titles and snippets. \
         Set depth=\"thorough\" to also fetch full page text — slower, so use it \
         only for comparisons, multi-source synthesis, or when snippets are \
         clearly insufficient; leave it \"quick\" (the default) for simple facts, \
         prices, and definitions."
    } else {
        "Search the web for current information. Returns titles and snippets."
    };
    tool_envelope("web_search", description, params)
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

    let status = if matches!(args.depth, SearchDepth::Thorough) {
        "searching the web (reading pages)…"
    } else {
        "searching the web…"
    };
    let _ = tx.send(TurnEvent::Status(status.into())).await;

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
            // The detail never contains message content (NFR-O7) — only the
            // backend failure cause — so log it so operators can diagnose
            // "web search unavailable" instead of it vanishing silently.
            tracing::warn!(error = %detail, "web_search failed");
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
        // Don't hand-set Accept-Encoding: reqwest only auto-decompresses a
        // response when *it* negotiated the encoding (via its `gzip` feature),
        // which we don't enable. Setting it manually yields raw gzip bytes that
        // `.json()` can't parse ("error decoding response body").
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

    let extracts = if cfg.search_fetch_pages && matches!(args.depth, SearchDepth::Thorough) {
        fetch_pages(cfg, http, &results).await
    } else {
        Vec::new()
    };

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
        let s = schema(false);
        assert_eq!(s["type"], "function");
        assert_eq!(s["function"]["name"], "web_search");
        assert!(s["function"]["parameters"]["properties"]["query"].is_object());
    }

    #[test]
    fn depth_param_is_gated_on_thorough_availability() {
        // Off: the model is never told about `depth`, so every search stays quick.
        let off = schema(false);
        assert!(off["function"]["parameters"]["properties"]["depth"].is_null());
        assert!(!off["function"]["description"]
            .as_str()
            .unwrap()
            .contains("thorough"));

        // On: `depth` is advertised with the quick/thorough enum.
        let on = schema(true);
        let depth = &on["function"]["parameters"]["properties"]["depth"];
        assert!(depth.is_object());
        assert!(on["function"]["description"]
            .as_str()
            .unwrap()
            .contains("thorough"));
    }

    #[test]
    fn depth_defaults_to_quick_when_absent() {
        let args: WebSearchArgs = serde_json::from_value(serde_json::json!({
            "query": "price of bitcoin"
        }))
        .unwrap();
        assert_eq!(args.depth, SearchDepth::Quick);
    }

    #[test]
    fn depth_parses_thorough() {
        let args: WebSearchArgs = serde_json::from_value(serde_json::json!({
            "query": "compare frameworks", "depth": "thorough"
        }))
        .unwrap();
        assert_eq!(args.depth, SearchDepth::Thorough);
    }
}
