//! Transient-failure handling for OpenAI-compatible upstream requests:
//! backoff policy, response classification, and `Retry-After` parsing.
//!
//! Adapted from goose (https://github.com/aaif-goose/goose, Apache-2.0),
//! `crates/goose-provider-types/src/retry.rs` and
//! `crates/goose-providers/src/http_status.rs`.
//!
//! Unlike the native-Ollama [`RetryPolicy`](crate::ollama), which exists for
//! the co-hosted cold-start window, this path may face a *shared* remote host
//! (vLLM behind a gateway, OpenRouter, …): backoff is jittered so the
//! orchestrator's concurrent turns don't retry in lockstep, and a 429's
//! server-provided `Retry-After` is honored over the computed backoff.
//!
//! Nothing here logs response bodies — an upstream error body can echo request
//! fragments (NFR-O7); callers log the status line only.

use std::time::{Duration, SystemTime};

use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};
use reqwest::header::{HeaderMap, RETRY_AFTER};
use reqwest::StatusCode;
use serde_json::Value;

use crate::error::AppError;

/// Retry budget and backoff shape for one request-initiation loop.
///
/// Timeouts are never retried regardless of budget: by the time the read
/// window fires the upstream has already spent it generating, and re-sending
/// re-runs that work on the GPU (same rationale as the Ollama path).
#[derive(Debug, Clone, Copy)]
pub struct RetryPolicy {
    /// Budget for 5xx and rate-limit responses.
    pub max_retries: u32,
    /// Budget for connection-level failures (host down, refused) — small, so
    /// a dead upstream fails fast instead of holding a concurrency permit.
    pub network_max_retries: u32,
    initial: Duration,
    multiplier: f64,
    cap: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        RetryPolicy {
            max_retries: 3,
            network_max_retries: 2,
            initial: Duration::from_secs(1),
            multiplier: 2.0,
            cap: Duration::from_secs(15),
        }
    }
}

/// Longest server-provided `Retry-After` we will actually sleep. The caller
/// holds the upstream's concurrency permit for the whole wait, so a server
/// asking for minutes gets this much patience and then its 429 back.
const MAX_HONORED_RETRY_AFTER: Duration = Duration::from_secs(60);

/// Hard cap on retry delays parsed out of remote responses. A malformed 429
/// with `retry_after_seconds: 1e30` (or a far-future HTTP-date) must degrade
/// to "no hint" rather than panic in `Duration::from_secs_f64`.
const MAX_RETRY_AFTER_SECS: f64 = 3600.0;

impl RetryPolicy {
    #[cfg(test)]
    pub fn fast() -> Self {
        RetryPolicy {
            initial: Duration::from_millis(1),
            cap: Duration::from_millis(5),
            ..RetryPolicy::default()
        }
    }

    /// Jittered exponential backoff for the given 1-based attempt. The 0.8–1.2
    /// jitter desynchronizes concurrent turns retrying against a shared host.
    pub fn delay(&self, attempt: u32) -> Duration {
        let exp = self.multiplier.powi(attempt.saturating_sub(1) as i32);
        self.initial.mul_f64(exp).min(self.cap).mul_f64(jitter())
    }

    /// The sleep before the given attempt: a server-provided rate-limit delay
    /// (capped — see [`MAX_HONORED_RETRY_AFTER`]) wins over computed backoff.
    pub fn delay_with_hint(&self, attempt: u32, retry_after: Option<Duration>) -> Duration {
        match retry_after {
            Some(hint) => hint.min(MAX_HONORED_RETRY_AFTER),
            None => self.delay(attempt),
        }
    }
}

/// 0.8–1.2 factor from the clock's sub-second nanos: enough spread to break
/// retry lockstep without pulling in a randomness dependency for it.
fn jitter() -> f64 {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    0.8 + f64::from(nanos % 1_000_000) / 1_000_000.0 * 0.4
}

/// What a failed response status means for the retry loop.
#[derive(Debug, PartialEq)]
pub enum Retryable {
    /// 5xx — worth the full retry budget.
    Server,
    /// 429 — full budget, sleeping the server-provided delay when present.
    RateLimited(Option<Duration>),
    /// Deterministic failure — retrying re-sends the identical payload to
    /// hit the same wall.
    No,
}

/// Classify a non-success response into the error to surface and whether the
/// caller should retry. `body` is the already-read response text.
pub fn classify_response(
    status: StatusCode,
    headers: &HeaderMap,
    body: &str,
) -> (AppError, Retryable) {
    let payload: Option<Value> = serde_json::from_str(body).ok();
    let message = payload
        .as_ref()
        .and_then(|p| {
            p.get("error")
                .and_then(|e| e.get("message"))
                .or_else(|| p.get("message"))
                .and_then(Value::as_str)
        })
        .unwrap_or(body);

    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => (
            AppError::UpstreamError(format!(
                "upstream authentication failed ({status}): {message}"
            )),
            Retryable::No,
        ),
        StatusCode::PAYLOAD_TOO_LARGE => (
            AppError::PayloadTooLarge(format!("upstream rejected request size: {message}")),
            Retryable::No,
        ),
        StatusCode::BAD_REQUEST if is_context_length_exceeded_message(message) => (
            // The client's history no longer fits the served window; a 400
            // tells the app it must shrink the request, where a 502 would
            // read as "try again".
            AppError::BadRequest(format!("upstream context window exceeded: {message}")),
            Retryable::No,
        ),
        StatusCode::TOO_MANY_REQUESTS => (
            AppError::UpstreamError(format!("{status}: {body}")),
            Retryable::RateLimited(extract_retry_after(headers, payload.as_ref())),
        ),
        _ if status.is_server_error() => (
            AppError::UpstreamError(format!("{status}: {body}")),
            Retryable::Server,
        ),
        _ => (
            AppError::UpstreamError(format!("{status}: {body}")),
            Retryable::No,
        ),
    }
}

/// Whether an error message describes the *prompt* overflowing the model's
/// context window — as opposed to output caps, quotas, or other limits.
/// OpenAI-compatible hosts phrase this many ways; the phrase lists come from
/// goose's table-tested classifier.
pub fn is_context_length_exceeded_message(text: &str) -> bool {
    let text_lower = text.to_lowercase();

    let direct_context_phrases = [
        "context length",
        "context_length_exceeded",
        "context window",
        "context_window_exceeded",
        "context limit",
        "maximum context",
        "max context",
        "maximum prompt length",
        "max prompt length",
    ];
    if direct_context_phrases
        .iter()
        .any(|phrase| text_lower.contains(phrase))
    {
        return true;
    }

    if text_lower.contains("reduce the length")
        && ["message", "messages", "input", "prompt"]
            .iter()
            .any(|word| text_lower.contains(word))
    {
        return true;
    }

    if [
        "input is too long",
        "input too long",
        "prompt is too long",
        "prompt too long",
    ]
    .iter()
    .any(|phrase| text_lower.contains(phrase))
    {
        return true;
    }

    let mentions_prompt_input_tokens = [
        "input token",
        "input length",
        "prompt token",
        "prompt length",
        "message token",
        "messages token",
        "request token",
        "total token",
    ]
    .iter()
    .any(|phrase| text_lower.contains(phrase));
    let mentions_limit = [
        "model limit",
        "model's limit",
        "maximum allowed",
        "max allowed",
        "maximum number of tokens",
        "token limit",
        "tokens limit",
    ]
    .iter()
    .any(|phrase| text_lower.contains(phrase));
    let mentions_overflow = ["exceed", "too long", "too large", "over the limit"]
        .iter()
        .any(|phrase| text_lower.contains(phrase));

    mentions_prompt_input_tokens && mentions_limit && mentions_overflow
}

/// Extract a retry delay from a 429 response. Prefers the body's
/// `error.metadata.retry_after_seconds` (OpenRouter's shape, more precise than
/// the integer header) and falls back to the RFC 7231 `Retry-After` header in
/// either its delay-seconds or HTTP-date form.
fn extract_retry_after(headers: &HeaderMap, payload: Option<&Value>) -> Option<Duration> {
    if let Some(secs) = payload
        .and_then(|p| p.get("error"))
        .and_then(|e| e.get("metadata"))
        .and_then(|m| m.get("retry_after_seconds"))
        .and_then(Value::as_f64)
    {
        if let Some(d) = duration_from_finite_secs(secs) {
            return Some(d);
        }
    }

    headers
        .get(RETRY_AFTER)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| parse_retry_after_header(s.trim()))
}

/// Convert a finite, non-negative, in-range seconds value to a `Duration`.
/// `None` for NaN, negative, or infinite inputs — `Duration::from_secs_f64`
/// panics on out-of-range values.
fn duration_from_finite_secs(secs: f64) -> Option<Duration> {
    if !secs.is_finite() || secs < 0.0 {
        return None;
    }
    Some(Duration::from_secs_f64(secs.min(MAX_RETRY_AFTER_SECS)))
}

/// Parse `Retry-After` per RFC 7231 §7.1.3: either a non-negative integer
/// number of seconds, or an HTTP-date (the absolute time at which the request
/// may be retried). A past date is honored as "retry now" (`Duration::ZERO`)
/// rather than dropped — clock skew plus network latency commonly produce an
/// HTTP-date already in the past, and an explicit server hint beats falling
/// back to exponential backoff.
fn parse_retry_after_header(value: &str) -> Option<Duration> {
    if let Ok(secs) = value.parse::<u64>() {
        return duration_from_finite_secs(secs as f64);
    }
    let target = parse_http_date(value)?;
    let delay = target
        .duration_since(SystemTime::now())
        .unwrap_or(Duration::ZERO);
    duration_from_finite_secs(delay.as_secs_f64())
}

/// Parse the three HTTP-date forms RFC 7231 §7.1.1.1 requires recipients to
/// accept: IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the obsolete RFC 850
/// form (`Sunday, 06-Nov-94 08:49:37 GMT`), and asctime (`Sun Nov  6 08:49:37
/// 1994`). All three are interpreted as GMT.
fn parse_http_date(value: &str) -> Option<SystemTime> {
    let value = value.trim();
    if let Ok(dt) = DateTime::parse_from_rfc2822(value) {
        return Some(SystemTime::from(dt));
    }
    if let Some(body) = value.strip_suffix(" GMT") {
        if let Ok(naive) = NaiveDateTime::parse_from_str(body, "%A, %d-%b-%y %H:%M:%S") {
            return Some(SystemTime::from(Utc.from_utc_datetime(&naive)));
        }
    }
    if let Ok(naive) = NaiveDateTime::parse_from_str(value, "%a %b %e %H:%M:%S %Y") {
        return Some(SystemTime::from(Utc.from_utc_datetime(&naive)));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn headers_with_retry_after(value: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(RETRY_AFTER, value.parse().unwrap());
        h
    }

    #[test]
    fn delay_backs_off_exponentially_within_jitter_bounds() {
        let policy = RetryPolicy::default();
        for (attempt, base_ms) in [(1u32, 1000u64), (2, 2000), (3, 4000)] {
            let d = policy.delay(attempt).as_millis() as u64;
            let (lo, hi) = (base_ms * 8 / 10, base_ms * 12 / 10);
            assert!(
                (lo..=hi).contains(&d),
                "attempt {attempt}: {d}ms outside [{lo}, {hi}]"
            );
        }
    }

    #[test]
    fn delay_is_capped_before_jitter() {
        let policy = RetryPolicy::default();
        // Attempt 30 would be ~2^29 seconds un-capped.
        let d = policy.delay(30);
        assert!(d <= Duration::from_secs(18), "cap*1.2 max, got {d:?}");
    }

    #[test]
    fn rate_limit_hint_wins_over_backoff_and_is_capped() {
        let policy = RetryPolicy::default();
        assert_eq!(
            policy.delay_with_hint(1, Some(Duration::from_secs(7))),
            Duration::from_secs(7)
        );
        assert_eq!(
            policy.delay_with_hint(1, Some(Duration::from_secs(600))),
            MAX_HONORED_RETRY_AFTER
        );
    }

    #[test]
    fn classify_auth_failures_are_permanent() {
        for status in [StatusCode::UNAUTHORIZED, StatusCode::FORBIDDEN] {
            let (error, retry) = classify_response(status, &HeaderMap::new(), "no");
            assert_eq!(retry, Retryable::No);
            assert!(matches!(error, AppError::UpstreamError(_)));
        }
    }

    #[test]
    fn classify_context_length_400_maps_to_bad_request() {
        let body =
            json!({"error": {"message": "This model's maximum context length is 8192 tokens"}})
                .to_string();
        let (error, retry) = classify_response(StatusCode::BAD_REQUEST, &HeaderMap::new(), &body);
        assert_eq!(retry, Retryable::No);
        assert!(
            matches!(&error, AppError::BadRequest(m) if m.contains("context window exceeded")),
            "got {error:?}"
        );
    }

    #[test]
    fn classify_generic_400_stays_upstream_error() {
        let (error, retry) = classify_response(
            StatusCode::BAD_REQUEST,
            &HeaderMap::new(),
            "model not found",
        );
        assert_eq!(retry, Retryable::No);
        assert!(matches!(error, AppError::UpstreamError(_)));
    }

    #[test]
    fn classify_429_carries_header_delay() {
        let headers = headers_with_retry_after("17");
        let (_, retry) = classify_response(StatusCode::TOO_MANY_REQUESTS, &headers, "slow down");
        assert_eq!(retry, Retryable::RateLimited(Some(Duration::from_secs(17))));
    }

    #[test]
    fn classify_429_prefers_body_seconds_over_header() {
        let body = json!({"error": {"metadata": {"retry_after_seconds": 22.5}}}).to_string();
        let headers = headers_with_retry_after("5");
        let (_, retry) = classify_response(StatusCode::TOO_MANY_REQUESTS, &headers, &body);
        assert_eq!(
            retry,
            Retryable::RateLimited(Some(Duration::from_secs_f64(22.5)))
        );
    }

    #[test]
    fn classify_5xx_is_retryable() {
        let (_, retry) =
            classify_response(StatusCode::INTERNAL_SERVER_ERROR, &HeaderMap::new(), "oops");
        assert_eq!(retry, Retryable::Server);
    }

    #[test]
    fn retry_after_past_http_date_means_retry_now() {
        let headers = headers_with_retry_after("Fri, 31 Dec 1999 23:59:59 GMT");
        assert_eq!(
            extract_retry_after(&headers, None),
            Some(Duration::ZERO),
            "a past date is an explicit 'retry now', not a parse failure"
        );
    }

    #[test]
    fn retry_after_future_http_date_parsed() {
        let target = chrono::Utc::now() + chrono::Duration::seconds(45);
        let headers =
            headers_with_retry_after(&target.format("%a, %d %b %Y %H:%M:%S GMT").to_string());
        let delay = extract_retry_after(&headers, None).expect("future HTTP-date parses");
        assert!(
            delay >= Duration::from_secs(30) && delay <= Duration::from_secs(60),
            "expected ~45s, got {delay:?}"
        );
    }

    #[test]
    fn retry_after_parses_rfc850_http_date() {
        let target = chrono::Utc::now() + chrono::Duration::seconds(90);
        let headers =
            headers_with_retry_after(&target.format("%A, %d-%b-%y %H:%M:%S GMT").to_string());
        let delay = extract_retry_after(&headers, None).expect("rfc850 date parses");
        assert!(
            delay >= Duration::from_secs(60) && delay <= Duration::from_secs(120),
            "expected ~90s, got {delay:?}"
        );
    }

    #[test]
    fn retry_after_parses_asctime_http_date() {
        let target = chrono::Utc::now() + chrono::Duration::seconds(120);
        let headers = headers_with_retry_after(&target.format("%a %b %e %H:%M:%S %Y").to_string());
        let delay = extract_retry_after(&headers, None).expect("asctime date parses");
        assert!(
            delay >= Duration::from_secs(90) && delay <= Duration::from_secs(150),
            "expected ~120s, got {delay:?}"
        );
    }

    #[test]
    fn retry_after_rejects_negative_nan_and_garbage() {
        let payload = json!({"error": {"metadata": {"retry_after_seconds": -1.0}}});
        assert!(extract_retry_after(&HeaderMap::new(), Some(&payload)).is_none());
        let payload = json!({"error": {"metadata": {"retry_after_seconds": "soon"}}});
        assert!(extract_retry_after(&HeaderMap::new(), Some(&payload)).is_none());
        let payload = json!({"error": {"metadata": {"retry_after_seconds": f64::INFINITY}}});
        assert!(extract_retry_after(&HeaderMap::new(), Some(&payload)).is_none());
        assert!(extract_retry_after(&headers_with_retry_after("whenever"), None).is_none());
    }

    #[test]
    fn retry_after_clamps_absurd_body_seconds() {
        // Duration::from_secs_f64(1e30) panics; the clamp keeps the turn alive.
        let payload = json!({"error": {"metadata": {"retry_after_seconds": 1e30}}});
        assert_eq!(
            extract_retry_after(&HeaderMap::new(), Some(&payload)),
            Some(Duration::from_secs_f64(MAX_RETRY_AFTER_SECS))
        );
    }

    #[test]
    fn context_length_classifier_accepts_context_window_errors() {
        let messages = [
            "This request exceeds the maximum context length",
            "context_length_exceeded",
            "context window exceeded",
            "Input token count exceeds the maximum number of tokens allowed",
            "Please reduce the length of the messages",
            "prompt is too long for this model",
        ];
        for message in messages {
            assert!(
                is_context_length_exceeded_message(message),
                "expected context-length match for: {message}"
            );
        }
    }

    #[test]
    fn context_length_classifier_rejects_generic_bad_request_errors() {
        let messages = [
            "max_tokens must be less than or equal to 4096",
            "Requested max_tokens exceeds the model output limit",
            "Current token count exceeds your organization quota",
            "temperature exceeds maximum allowed value",
            "schema is too long",
            "metadata length exceeds maximum allowed",
        ];
        for message in messages {
            assert!(
                !is_context_length_exceeded_message(message),
                "expected generic bad request for: {message}"
            );
        }
    }
}
