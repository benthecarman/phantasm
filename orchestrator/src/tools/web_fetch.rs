//! Fetch and extract a specific HTTP(S) page. Stateless and bounded; no local
//! filesystem access and no non-HTTP schemes.

use std::net::IpAddr;
use std::time::Duration;

use futures_util::StreamExt;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use url::Url;

use crate::config::Config;
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
    http: &reqwest::Client,
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
        r = fetch(cfg, http, &args, ctx) => r,
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

async fn fetch(
    cfg: &Config,
    http: &reqwest::Client,
    args: &WebFetchArgs,
    ctx: &TurnContext,
) -> Result<String, String> {
    let url = validate_url(&args.url)?;
    let cache_key = url.as_str().to_string();
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
    let resp = http
        .get(url.clone())
        .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
        .timeout(Duration::from_millis(cfg.search_fetch_timeout_ms.max(1000)))
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

fn validate_url(raw: &str) -> Result<Url, String> {
    let url = Url::parse(raw).map_err(|e| format!("invalid URL: {e}"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err("only http and https URLs are allowed".into());
    }
    let Some(host) = url.host_str() else {
        return Err("URL has no host".into());
    };
    if host.eq_ignore_ascii_case("localhost") || host.ends_with(".localhost") {
        return Err("localhost URLs are not allowed".into());
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        if is_blocked_ip(ip) {
            return Err(
                "private, loopback, link-local, and unspecified IPs are not allowed".into(),
            );
        }
    }
    Ok(url)
}

fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            ip.is_private()
                || ip.is_loopback()
                || ip.is_link_local()
                || ip.is_broadcast()
                || ip.is_documentation()
                || ip.is_unspecified()
        }
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_unspecified()
                || ip.is_unique_local()
                || ip.is_unicast_link_local()
        }
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
    use super::*;

    #[test]
    fn rejects_non_http_and_localhost() {
        assert!(validate_url("file:///etc/passwd").is_err());
        assert!(validate_url("http://localhost:8080").is_err());
        assert!(validate_url("http://127.0.0.1:8080").is_err());
        assert!(validate_url("https://example.com/page").is_ok());
    }
}
