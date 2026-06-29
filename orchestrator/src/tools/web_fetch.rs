//! Fetch and extract a specific HTTP(S) page. Stateless and bounded; no local
//! filesystem access and no non-HTTP schemes. The target URL is model-chosen, so
//! every fetch goes through the shared SSRF guard ([`crate::net_guard`]): the host
//! is resolved and screened, the connection is pinned to the validated IP, and
//! redirects are refused (a 3xx to an internal resource can't re-resolve past the
//! guard).

use std::time::Duration;

use futures_util::StreamExt;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::net_guard;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome, TurnContext};
use crate::orchestrator::TurnEvent;
use crate::tools::web_search::html_to_text;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct WebFetchArgs {
    /// HTTP or HTTPS URL to fetch.
    pub url: String,
    /// Optional maximum extracted characters to return.
    #[serde(default)]
    pub max_chars: Option<usize>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(WebFetchArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "web_fetch",
        "Fetch a specific HTTP(S) URL and return extracted readable text. Use after web_search when a source needs closer reading.",
        params,
    )
}

pub async fn run(
    cfg: &Config,
    call: &ToolCall,
    call_id: &str,
    ctx: &TurnContext,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: WebFetchArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };
    let _ = tx.send(TurnEvent::Status("fetching page…".into())).await;

    let result = tokio::select! {
        r = fetch(cfg, &args, ctx) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok(text) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "web_fetch", text),
            append_to_answer: None,
        },
        Err(e) => {
            tracing::warn!(error = %e, "web_fetch failed");
            error_outcome(call_id, e)
        }
    }
}

async fn fetch(cfg: &Config, args: &WebFetchArgs, ctx: &TurnContext) -> Result<String, String> {
    // SSRF guard: resolve + screen the host and pin the connection to the
    // validated IP, with redirects disabled (see module docs).
    let target = net_guard::guard_url(&args.url).await?;
    let cache_key = target.url.as_str().to_string();
    if let Some(hit) = ctx
        .cache
        .lock()
        .ok()
        .and_then(|c| c.pages.get(&cache_key).cloned())
    {
        return hit.ok_or_else(|| format!("previous fetch failed for {cache_key}"));
    }

    let cap = args
        .max_chars
        .unwrap_or(cfg.web_fetch_context_chars)
        .clamp(500, cfg.web_fetch_context_chars);
    let body_cap = cap.saturating_mul(4).saturating_add(8192);
    let timeout = Duration::from_millis(cfg.search_fetch_timeout_ms.max(1000));
    let client = net_guard::pinned_client(&target, timeout)?;
    let resp = client
        .get(target.url.clone())
        .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
        .send()
        .await
        .map_err(|e| e.to_string())?;

    if !resp.status().is_success() {
        let status = resp.status();
        cache_page(ctx, &cache_key, None);
        return Err(format!("HTTP {status} fetching {cache_key}"));
    }
    if let Some(len) = resp.content_length() {
        if len as usize > body_cap {
            cache_page(ctx, &cache_key, None);
            return Err(format!("response too large ({len} bytes > {body_cap} cap)"));
        }
    }

    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();

    let mut bytes = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        if bytes.len() + chunk.len() > body_cap {
            cache_page(ctx, &cache_key, None);
            return Err(format!("response exceeds {body_cap} byte cap"));
        }
        bytes.extend_from_slice(&chunk);
    }

    let raw = String::from_utf8_lossy(&bytes);
    let text = if content_type.contains("html") {
        html_to_text(&raw, cap)
    } else {
        raw.split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(cap)
            .collect()
    };
    let out = format!("Fetched page:\nurl: {cache_key}\n\n{text}");
    cache_page(ctx, &cache_key, Some(out.clone()));
    Ok(out)
}

fn cache_page(ctx: &TurnContext, url: &str, text: Option<String>) {
    if let Ok(mut cache) = ctx.cache.lock() {
        cache.pages.insert(url.to_string(), text);
    }
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "web_fetch",
            format!("web_fetch failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use crate::net_guard::guard_url;

    // URL validation lives in the shared net_guard (resolution + IP screening +
    // connection pinning), exercised here at the boundary web_fetch relies on:
    // non-HTTP schemes, localhost, and internal IP literals are all refused, so
    // a model-chosen URL can't reach loopback/link-local/metadata targets.
    #[tokio::test]
    async fn rejects_non_http_localhost_and_internal_literals() {
        assert!(guard_url("file:///etc/passwd").await.is_err());
        assert!(guard_url("http://localhost:8080").await.is_err());
        assert!(guard_url("http://127.0.0.1:8080").await.is_err());
        assert!(guard_url("http://169.254.169.254/latest/meta-data")
            .await
            .is_err());
        assert!(guard_url("http://[::1]:8080").await.is_err());
    }
}
