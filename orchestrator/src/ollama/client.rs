//! Hand-rolled async client for Ollama's native `/api/chat` (NDJSON) API.

use std::time::Duration;

use async_stream::try_stream;
use bytes::{Bytes, BytesMut};
use futures_util::{Stream, StreamExt};
use serde_json::{Map, Value};
use url::Url;

use super::types::{
    ModelMetadata, OllamaChatChunk, OllamaChatRequest, OllamaMessage, ShowResponse, TagsResponse,
};
use super::{ChatBackend, DeltaStream, StreamDelta, ToolDeltaStream, ToolStreamDelta};
use crate::error::AppError;
use crate::openai::types::{ChatMessage, ToolCall};

/// Explicit residency hint for the opt-in warm preload path.
const WARM_KEEP_ALIVE: &str = "30m";

/// Bound on the lazy `/api/show` probe in `resolve_num_ctx` — it precedes a
/// chat call, so it must never inherit the shared client's 120s read window.
const METADATA_PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// How long a FAILED `/api/show` probe suppresses re-probing. A failure must
/// not be cached forever — the likeliest failure moment is exactly co-hosted
/// boot (Ollama not yet listening), and a permanent verdict would silently
/// disable num_ctx injection until restart. A short cooldown keeps a broken
/// endpoint from taxing every call while letting a booting one recover.
const CTX_PROBE_RETRY_COOLDOWN: Duration = Duration::from_secs(60);

/// One model's `/api/show` probe outcome (see `resolve_num_ctx`).
#[derive(Clone, Copy)]
enum CtxProbe {
    /// Definitive: metadata fetched; `None` = it reports no context length.
    Declared(Option<u64>),
    /// The probe failed; retry after [`CTX_PROBE_RETRY_COOLDOWN`].
    FailedAt(std::time::Instant),
}

/// Cold-start retry for `/api/chat` request *initiation*. While a large model
/// loads into memory (30–120s), Ollama can answer 500; without retries the
/// first chat after an idle period fails outright. Failures are classified,
/// because the caller holds the upstream's concurrency permit for the whole
/// window — blind retrying pins a GPU slot:
///   * 5xx — the load window — gets the full budget (`max_retries`, ~100s of
///     backoff), except bodies matching [`PERMANENT_5XX_MARKERS`], which can
///     never succeed and fail immediately.
///   * network/send errors (daemon down, connection refused) get the small
///     `network_max_retries` budget (~5s) so a dead upstream fails fast.
///   * timeouts are NOT retried: for a non-streaming call the timeout fires
///     after the upstream already spent up to the full read window
///     generating, and re-sending re-runs that work on the GPU.
///   * 4xx is a real request problem and returns immediately.
///
/// Mid-stream errors after a response has started are not retried; the shared
/// HTTP client's per-read timeout governs those. Backoff tuning follows
/// goose's Ollama provider: capped intervals so a ready server is picked up
/// quickly. No jitter — one orchestrator process, concurrency already bounded
/// per upstream (NFR-O2).
#[derive(Debug, Clone, Copy)]
struct RetryPolicy {
    max_retries: u32,
    network_max_retries: u32,
    initial: Duration,
    multiplier: f64,
    cap: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        RetryPolicy {
            max_retries: 10,
            network_max_retries: 2,
            initial: Duration::from_millis(2000),
            multiplier: 1.5,
            cap: Duration::from_secs(15),
        }
    }
}

impl RetryPolicy {
    /// No retries at all — for best-effort paths (`/v1/warm`) whose contract
    /// is to fail fast rather than hold a concurrency permit.
    fn none() -> Self {
        RetryPolicy {
            max_retries: 0,
            network_max_retries: 0,
            ..RetryPolicy::default()
        }
    }

    fn delay(&self, attempt: u32) -> Duration {
        let exp = self.multiplier.powi(attempt.saturating_sub(1) as i32);
        self.initial.mul_f64(exp).min(self.cap)
    }
}

/// Substrings marking a 5xx body as deterministic — retrying re-pays the full
/// backoff window to hit the same wall. Extend as more are observed.
const PERMANENT_5XX_MARKERS: &[&str] = &["requires more system memory"];

#[derive(Clone)]
pub struct OllamaClient {
    http: reqwest::Client,
    base: Url,
    /// Metrics registry for token-usage recording. Attached once at startup;
    /// `None` in tests and probes, which record nothing. Living here (not in
    /// the `ChatBackend` trait) keeps the trait — and its scripted test
    /// impls — untouched.
    metrics: Option<std::sync::Arc<crate::metrics::Metrics>>,
    /// Cap on the `num_ctx` injected from the model's declared context length
    /// (see `resolve_num_ctx`). `0` disables injection entirely.
    num_ctx_cap: u64,
    /// Per-model `/api/show` probe outcome, shared across clones (probes,
    /// warm, chat). Seeded by the capability probing (startup + TTL refresh)
    /// and filled lazily on first use otherwise; failures carry a cooldown.
    ctx_len_cache: std::sync::Arc<std::sync::RwLock<std::collections::HashMap<String, CtxProbe>>>,
    /// Failure cooldown, a field only so tests can shrink it.
    ctx_probe_cooldown: Duration,
    /// Cold-start retry tuning for chat request initiation (see [`RetryPolicy`]).
    retry: RetryPolicy,
}

impl OllamaClient {
    pub fn new(http: reqwest::Client, base: Url) -> Self {
        OllamaClient {
            http,
            base,
            metrics: None,
            num_ctx_cap: 0,
            ctx_len_cache: Default::default(),
            ctx_probe_cooldown: CTX_PROBE_RETRY_COOLDOWN,
            retry: RetryPolicy::default(),
        }
    }

    /// Feed a context length probed elsewhere (startup + TTL capability
    /// probing, see `detect_model_metadata`) so the first chat per model
    /// doesn't pay its own `/api/show` round-trip — and a model re-pull
    /// propagates on the next capabilities refresh instead of never.
    pub fn seed_context_length(&self, model: &str, context_length: Option<u64>) {
        self.ctx_len_cache
            .write()
            .expect("poisoned")
            .insert(model.to_string(), CtxProbe::Declared(context_length));
    }

    #[cfg(test)]
    fn set_ctx_probe_cooldown(&mut self, cooldown: Duration) {
        self.ctx_probe_cooldown = cooldown;
    }

    /// Tests shrink the backoff so retry paths run in milliseconds.
    #[cfg(test)]
    fn set_retry_policy(&mut self, retry: RetryPolicy) {
        self.retry = retry;
    }

    /// POST `body` to `/api/chat`, retrying transient initiation failures
    /// per [`RetryPolicy`]. `context` labels the calling path in logs.
    /// Cancellation-safe: the turn loop `select!`s on the caller, so a backoff
    /// sleep is simply dropped when the client disconnects.
    async fn post_chat(
        &self,
        body: &OllamaChatRequest,
        context: &'static str,
    ) -> Result<reqwest::Response, AppError> {
        self.post_chat_with(body, context, self.retry).await
    }

    async fn post_chat_with(
        &self,
        body: &OllamaChatRequest,
        context: &'static str,
        retry: RetryPolicy,
    ) -> Result<reqwest::Response, AppError> {
        let url = self.endpoint("/api/chat")?;
        let model = &body.model;
        let mut attempt = 0u32;
        loop {
            // `cause` is what gets LOGGED: the status line or the reqwest
            // error (URL + error kind). The response body goes only into the
            // returned error for the client — an upstream 5xx body can echo
            // request fragments, and logging those un-gated would violate
            // NFR-O7.
            let (error, cause, budget) = match self.http.post(url.clone()).json(body).send().await {
                Ok(resp) if resp.status().is_success() => return Ok(resp),
                Ok(resp) => {
                    let status = resp.status();
                    let detail = resp.text().await.unwrap_or_default();
                    let error = AppError::UpstreamError(format!("{status}: {detail}"));
                    let permanent = PERMANENT_5XX_MARKERS.iter().any(|m| detail.contains(m));
                    if !status.is_server_error() || permanent {
                        tracing::warn!(model = %model, %status, permanent, context, "Ollama returned error status");
                        return Err(error);
                    }
                    (error, format!("HTTP {status}"), retry.max_retries)
                }
                Err(e) if e.is_timeout() => {
                    // The upstream may have spent the whole read window
                    // generating; re-sending re-runs that work on the GPU.
                    tracing::warn!(model = %model, cause = %e, context, "Ollama request timed out; not retrying");
                    return Err(AppError::UpstreamUnreachable(e.to_string()));
                }
                Err(e) => {
                    let cause = e.to_string();
                    (
                        AppError::UpstreamUnreachable(cause.clone()),
                        cause,
                        retry.network_max_retries,
                    )
                }
            };
            attempt += 1;
            if attempt > budget {
                tracing::warn!(model = %model, cause = %cause, attempts = attempt, context, "Ollama request failed; retries exhausted");
                return Err(error);
            }
            let delay = retry.delay(attempt);
            tracing::warn!(
                model = %model,
                cause = %cause,
                attempt,
                retry_in_ms = delay.as_millis() as u64,
                context,
                "transient Ollama failure (model may still be loading); retrying"
            );
            tokio::time::sleep(delay).await;
        }
    }

    pub fn set_metrics(&mut self, metrics: std::sync::Arc<crate::metrics::Metrics>) {
        self.metrics = Some(metrics);
    }

    pub fn set_num_ctx_cap(&mut self, cap: u64) {
        self.num_ctx_cap = cap;
    }

    /// The `num_ctx` to inject for `model`: `min(declared context length, cap)`.
    ///
    /// Ollama sizes its KV cache from its own server default (typically 4096)
    /// unless a request says otherwise, silently truncating longer histories —
    /// and per XR-2 the app resends the full history every turn. The declared
    /// length comes from `/api/show`, fetched once per model and cached, so the
    /// value is stable across a turn's calls (a changed `num_ctx` would force
    /// Ollama to reload the model).
    ///
    /// `None` (inject nothing, keep Ollama's default) when injection is
    /// disabled (`cap == 0`), the request already carries a `num_ctx`, the
    /// metadata doesn't report a context length, or the metadata fetch fails.
    /// Only a definitive answer is cached permanently; a failed or timed-out
    /// probe is cached with a cooldown — long enough that a persistently
    /// failing `/api/show` (a proxy forwarding only `/api/chat`) doesn't tax
    /// every call, short enough that one refused connection at co-hosted boot
    /// doesn't silently disable injection until restart.
    async fn resolve_num_ctx(&self, model: &str, options: &Map<String, Value>) -> Option<u64> {
        if self.num_ctx_cap == 0 || options.contains_key("num_ctx") {
            return None;
        }
        let cached = self
            .ctx_len_cache
            .read()
            .expect("poisoned")
            .get(model)
            .copied();
        let declared = match cached {
            Some(CtxProbe::Declared(declared)) => declared,
            Some(CtxProbe::FailedAt(at)) if at.elapsed() < self.ctx_probe_cooldown => None,
            _ => {
                let probe =
                    tokio::time::timeout(METADATA_PROBE_TIMEOUT, self.model_metadata(model)).await;
                let outcome = match probe {
                    Ok(Ok(metadata)) => CtxProbe::Declared(metadata.context_length),
                    Ok(Err(e)) => {
                        tracing::warn!(model = %model, error = %e, "num_ctx metadata probe failed; keeping Ollama's default for now");
                        CtxProbe::FailedAt(std::time::Instant::now())
                    }
                    Err(_) => {
                        tracing::warn!(model = %model, "num_ctx metadata probe timed out; keeping Ollama's default for now");
                        CtxProbe::FailedAt(std::time::Instant::now())
                    }
                };
                self.ctx_len_cache
                    .write()
                    .expect("poisoned")
                    .insert(model.to_string(), outcome);
                match outcome {
                    CtxProbe::Declared(declared) => declared,
                    CtxProbe::FailedAt(_) => None,
                }
            }
        };
        declared.map(|len| len.min(self.num_ctx_cap))
    }

    /// Clone the request options and inject the resolved `num_ctx` (see
    /// [`Self::resolve_num_ctx`]); the result feeds `build_request`.
    async fn prepare_options(
        &self,
        model: &str,
        options: &Map<String, Value>,
    ) -> Map<String, Value> {
        let mut options = options.clone();
        if let Some(num_ctx) = self.resolve_num_ctx(model, &options).await {
            options.insert("num_ctx".into(), num_ctx.into());
        }
        options
    }

    fn endpoint(&self, path: &str) -> Result<Url, AppError> {
        self.base
            .join(path)
            .map_err(|e| AppError::Internal(format!("bad Ollama URL: {e}")))
    }

    fn build_request(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        mut options: Map<String, Value>,
        stream: bool,
        keep_alive: Option<&str>,
    ) -> OllamaChatRequest {
        let think = extract_thinking_control(&mut options);
        options.remove("tool_choice");
        translate_output_cap(&mut options);
        OllamaChatRequest {
            model: model.to_string(),
            messages: messages.iter().map(OllamaMessage::from_openai).collect(),
            tools: if tools.is_empty() {
                None
            } else {
                Some(tools.to_vec())
            },
            stream,
            think,
            options: if options.is_empty() {
                None
            } else {
                Some(Value::Object(options))
            },
            keep_alive: keep_alive.map(str::to_string),
        }
    }

    /// List locally available models via `/api/tags`. Used for capabilities.
    pub async fn list_models(&self) -> Result<Vec<String>, AppError> {
        let url = self.endpoint("/api/tags")?;
        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }

        let tags: TagsResponse = resp
            .json()
            .await
            .map_err(|e| AppError::UpstreamError(e.to_string()))?;
        Ok(tags.models.into_iter().map(|m| m.name).collect())
    }

    /// Declared metadata of a model via `/api/show` (e.g. capabilities and
    /// context window).
    pub async fn model_metadata(&self, model: &str) -> Result<ModelMetadata, AppError> {
        let url = self.endpoint("/api/show")?;
        let resp = self
            .http
            .post(url)
            .json(&serde_json::json!({ "model": model }))
            .send()
            .await
            .map_err(|e| AppError::UpstreamUnreachable(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(AppError::UpstreamError(format!("{status}: {detail}")));
        }

        let show: ShowResponse = resp
            .json()
            .await
            .map_err(|e| AppError::UpstreamError(e.to_string()))?;
        Ok(show.into())
    }

    /// Declared capabilities of a model via `/api/show` (e.g. `"vision"`,
    /// `"tools"`). Used by focused tests and older internal callers.
    pub async fn model_capabilities(&self, model: &str) -> Result<Vec<String>, AppError> {
        Ok(self.model_metadata(model).await?.capabilities)
    }

    /// Best-effort model preload used only by `POST /v1/warm`. Loads with the
    /// same `num_ctx` real chats will use — a differing value would make the
    /// first chat reload the model, defeating the warm.
    pub async fn warm_model(&self, model: &str) -> Result<(), AppError> {
        let options = self.prepare_options(model, &Map::new()).await;
        let body = self.build_request(model, &[], &[], options, false, Some(WARM_KEEP_ALIVE));
        // No retries: warm is documented fast best-effort — a down backend
        // must not hold the route (and its semaphore permit) for a backoff
        // window. The load-window 500s retry logic belongs to real chats.
        self.post_chat_with(&body, "warm", RetryPolicy::none())
            .await?;
        Ok(())
    }
}

impl ChatBackend for OllamaClient {
    async fn chat_once(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> Result<ChatMessage, AppError> {
        let options = self.prepare_options(model, options).await;
        let body = self.build_request(model, messages, tools, options, false, None);
        tracing::debug!(
            model = %model,
            messages = messages.len(),
            tools = tools.len(),
            "upstream chat_once (/api/chat, non-streaming)"
        );
        let resp = self.post_chat(&body, "chat_once").await?;

        let chunk: OllamaChatChunk = resp
            .json()
            .await
            .map_err(|e| AppError::UpstreamError(e.to_string()))?;
        record_chunk_usage(&usage_recorder(&self.metrics, model), &chunk);
        Ok(chunk.message.unwrap_or_default().into_openai())
    }

    async fn chat_stream(
        &self,
        model: &str,
        messages: &[ChatMessage],
        options: &Map<String, Value>,
    ) -> Result<DeltaStream, AppError> {
        let options = self.prepare_options(model, options).await;
        let body = self.build_request(model, messages, &[], options, true, None);
        tracing::debug!(
            model = %model,
            messages = messages.len(),
            "upstream chat_stream (/api/chat, streaming)"
        );
        let resp = self.post_chat(&body, "chat_stream").await?;

        let stream = ndjson_to_deltas(resp.bytes_stream(), usage_recorder(&self.metrics, model));
        Ok(Box::pin(stream))
    }

    async fn chat_stream_tools(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[Value],
        options: &Map<String, Value>,
    ) -> Result<Option<ToolDeltaStream>, AppError> {
        let options = self.prepare_options(model, options).await;
        let body = self.build_request(model, messages, tools, options, true, None);
        tracing::debug!(
            model = %model,
            messages = messages.len(),
            tools = tools.len(),
            "upstream chat_stream_tools (/api/chat, streaming)"
        );
        let resp = self.post_chat(&body, "chat_stream_tools").await?;

        let stream =
            ndjson_to_tool_deltas(resp.bytes_stream(), usage_recorder(&self.metrics, model));
        Ok(Some(Box::pin(stream)))
    }
}

/// A metrics handle bound to the model of one request, for recording the
/// final chunk's generation stats. `None` => record nothing.
type UsageRecorder = Option<(std::sync::Arc<crate::metrics::Metrics>, String)>;

fn usage_recorder(
    metrics: &Option<std::sync::Arc<crate::metrics::Metrics>>,
    model: &str,
) -> UsageRecorder {
    metrics.as_ref().map(|m| (m.clone(), model.to_string()))
}

/// Feed a chunk's generation stats (present only on the final chunk) into the
/// registry. Intermediate chunks carry no counts and record nothing.
fn record_chunk_usage(recorder: &UsageRecorder, chunk: &OllamaChatChunk) {
    if let Some((metrics, model)) = recorder {
        metrics.record_usage(
            model,
            chunk.prompt_eval_count,
            chunk.eval_count,
            chunk.eval_duration,
            chunk.load_duration,
        );
    }
}

/// Turn a stream of raw byte chunks (NDJSON) into a stream of `StreamDelta`s,
/// buffering partial lines across chunk boundaries.
fn ndjson_to_deltas<S>(
    mut bytes: S,
    usage: UsageRecorder,
) -> impl Stream<Item = Result<StreamDelta, AppError>>
where
    S: Stream<Item = reqwest::Result<Bytes>> + Unpin,
{
    try_stream! {
        let mut buf = BytesMut::new();
        while let Some(next) = bytes.next().await {
            let chunk = next.map_err(|e| AppError::UpstreamError(e.to_string()))?;
            buf.extend_from_slice(&chunk);

            // Emit one delta per complete `\n`-terminated JSON line.
            while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line = buf.split_to(pos + 1);
                let trimmed = line.as_ref();
                if trimmed.iter().all(|b| b.is_ascii_whitespace()) {
                    continue;
                }
                let parsed: OllamaChatChunk = serde_json::from_slice(trimmed)
                    .map_err(|e| AppError::UpstreamError(format!("bad NDJSON line: {e}")))?;
                record_chunk_usage(&usage, &parsed);
                yield delta_from(parsed);
            }
        }

        // Flush any trailing line without a newline (defensive).
        let rest = buf.as_ref();
        if !rest.iter().all(|b| b.is_ascii_whitespace()) {
            if let Ok(parsed) = serde_json::from_slice::<OllamaChatChunk>(rest) {
                record_chunk_usage(&usage, &parsed);
                yield delta_from(parsed);
            }
        }
    }
}

/// Turn native Ollama streaming-with-tools NDJSON into tool-resolution deltas.
/// Ollama may emit parallel tool calls across multiple chunks, so hold calls
/// until the stream finishes and then emit one complete batch.
fn ndjson_to_tool_deltas<S>(
    mut bytes: S,
    usage: UsageRecorder,
) -> impl Stream<Item = Result<ToolStreamDelta, AppError>>
where
    S: Stream<Item = reqwest::Result<Bytes>> + Unpin,
{
    try_stream! {
        let mut buf = BytesMut::new();
        let mut pending_tool_calls = Vec::<ToolCall>::new();
        while let Some(next) = bytes.next().await {
            let chunk = next.map_err(|e| AppError::UpstreamError(e.to_string()))?;
            buf.extend_from_slice(&chunk);

            while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line = buf.split_to(pos + 1);
                let trimmed = line.as_ref();
                if trimmed.iter().all(|b| b.is_ascii_whitespace()) {
                    continue;
                }
                let parsed: OllamaChatChunk = serde_json::from_slice(trimmed)
                    .map_err(|e| AppError::UpstreamError(format!("bad NDJSON line: {e}")))?;
                record_chunk_usage(&usage, &parsed);
                if let Some(delta) = tool_delta_from(parsed, &mut pending_tool_calls) {
                    yield delta;
                }
            }
        }

        let rest = buf.as_ref();
        if !rest.iter().all(|b| b.is_ascii_whitespace()) {
            if let Ok(parsed) = serde_json::from_slice::<OllamaChatChunk>(rest) {
                record_chunk_usage(&usage, &parsed);
                if let Some(delta) = tool_delta_from(parsed, &mut pending_tool_calls) {
                    yield delta;
                }
            }
        }

        if !pending_tool_calls.is_empty() {
            yield ToolStreamDelta::new("", "", Some(std::mem::take(&mut pending_tool_calls)), true, Some("tool_calls".into()));
        }
    }
}

fn delta_from(chunk: OllamaChatChunk) -> StreamDelta {
    let message = chunk.message.unwrap_or_default();
    StreamDelta::new(
        message.content.unwrap_or_default(),
        message.thinking.unwrap_or_default(),
        chunk.done,
        chunk.done_reason,
    )
}

fn tool_delta_from(
    chunk: OllamaChatChunk,
    pending_tool_calls: &mut Vec<ToolCall>,
) -> Option<ToolStreamDelta> {
    let message = chunk.message.unwrap_or_default();
    if let Some(mut calls) = message.clone().into_openai().tool_calls {
        pending_tool_calls.append(&mut calls);
    }

    if chunk.done {
        let content = message.content.unwrap_or_default();
        let reasoning = message.thinking.unwrap_or_default();
        return Some(ToolStreamDelta::new(
            if pending_tool_calls.is_empty() {
                content
            } else {
                String::new()
            },
            if pending_tool_calls.is_empty() {
                reasoning
            } else {
                String::new()
            },
            (!pending_tool_calls.is_empty()).then(|| std::mem::take(pending_tool_calls)),
            true,
            chunk.done_reason,
        ));
    }

    if pending_tool_calls.is_empty() {
        let content = message.content.unwrap_or_default();
        let reasoning = message.thinking.unwrap_or_default();
        if !content.is_empty() || !reasoning.is_empty() {
            return Some(ToolStreamDelta::new(content, reasoning, None, false, None));
        }
    }

    None
}

/// Translate the OpenAI output-length cap to the native option. Standard
/// clients send `max_tokens` (or `max_completion_tokens` for reasoning
/// models); `/api/chat` only understands `options.num_predict` and would
/// silently ignore the OpenAI names. An explicit `num_predict` wins.
fn translate_output_cap(options: &mut Map<String, Value>) {
    // Remove BOTH OpenAI names unconditionally — a client may send the pair,
    // and a leftover would reach /api/chat as an unknown option.
    let max_completion_tokens = options.remove("max_completion_tokens");
    let max_tokens = options.remove("max_tokens");
    if let Some(cap) = max_completion_tokens.or(max_tokens) {
        options.entry("num_predict").or_insert(cap);
    }
}

/// Read the requested thinking control and strip the reasoning keys so they are
/// not forwarded to `/api/chat` (which expects the native `think` flag instead).
fn extract_thinking_control(options: &mut Map<String, Value>) -> Option<bool> {
    let think = crate::openai::types::requested_thinking(options)?;
    // Remove whichever key carried it (removing an absent key is a no-op).
    options.remove("reasoning_effort");
    options.remove("reasoning");
    Some(think)
}

#[cfg(test)]
mod tests {
    use super::{extract_thinking_control, ndjson_to_deltas, ndjson_to_tool_deltas, OllamaClient};
    use crate::error::AppError;
    use crate::ollama::{StreamDelta, ToolStreamDelta};
    use bytes::Bytes;
    use futures_util::{stream, StreamExt};
    use serde_json::{json, Map, Value};
    use url::Url;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    async fn collect(chunks: Vec<reqwest::Result<Bytes>>) -> Vec<Result<StreamDelta, AppError>> {
        ndjson_to_deltas(stream::iter(chunks), None).collect().await
    }

    async fn collect_tool_deltas(
        chunks: Vec<reqwest::Result<Bytes>>,
    ) -> Vec<Result<ToolStreamDelta, AppError>> {
        ndjson_to_tool_deltas(stream::iter(chunks), None)
            .collect()
            .await
    }

    #[tokio::test]
    async fn ndjson_reassembles_line_split_across_chunks() {
        // One NDJSON object deliberately split mid-JSON, then a terminal line.
        let chunks: Vec<reqwest::Result<Bytes>> = vec![
            Ok(Bytes::from_static(b"{\"message\":{\"role\":\"assistant\",\"content\":\"He")),
            Ok(Bytes::from_static(
                b"llo\"},\"done\":false}\n{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\"}\n",
            )),
        ];
        let deltas: Vec<StreamDelta> = collect(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(deltas.len(), 2);
        assert_eq!(deltas[0].content, "Hello");
        assert!(!deltas[0].done);
        assert!(deltas[1].done);
        assert_eq!(deltas[1].done_reason.as_deref(), Some("stop"));
    }

    #[tokio::test]
    async fn ndjson_carries_thinking_as_reasoning() {
        let chunks = vec![Ok(Bytes::from_static(
            b"{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"thinking\":\"hmm\"},\"done\":false}\n",
        ))];
        let deltas: Vec<StreamDelta> = collect(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0].reasoning, "hmm");
    }

    #[tokio::test]
    async fn ndjson_flushes_trailing_line_without_newline() {
        // A final object arriving without its terminating newline is still emitted.
        let chunks = vec![Ok(Bytes::from_static(
            b"{\"message\":{\"role\":\"assistant\",\"content\":\"tail\"},\"done\":true}",
        ))];
        let deltas: Vec<StreamDelta> = collect(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0].content, "tail");
        assert!(deltas[0].done);
    }

    #[tokio::test]
    async fn ndjson_skips_blank_lines() {
        let chunks = vec![Ok(Bytes::from_static(
            b"\n{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"done\":false}\n\n",
        ))];
        let deltas: Vec<StreamDelta> = collect(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0].content, "x");
    }

    #[tokio::test]
    async fn ndjson_final_chunk_records_usage() {
        let metrics = crate::metrics::Metrics::without_store();
        let chunks: Vec<reqwest::Result<Bytes>> = vec![Ok(Bytes::from_static(
            b"{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"done\":false}\n\
              {\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\
               \"prompt_eval_count\":10,\"eval_count\":30,\"eval_duration\":1500000000,\"load_duration\":2000000000}\n",
        ))];
        let deltas: Vec<StreamDelta> =
            ndjson_to_deltas(stream::iter(chunks), Some((metrics.clone(), "m1".into())))
                .collect::<Vec<_>>()
                .await
                .into_iter()
                .map(|r| r.unwrap())
                .collect();
        assert_eq!(deltas.len(), 2);
        let stats = metrics.model("m1");
        assert_eq!(stats.prompt_tokens.get(), 10);
        assert_eq!(stats.completion_tokens.get(), 30);
        // 30 tokens / 1.5s = 20 tok/s.
        assert_eq!(stats.tokens_per_sec.snapshot().count, 1);
        assert_eq!(stats.model_load.snapshot().count, 1);
    }

    #[tokio::test]
    async fn ndjson_tool_stream_accumulates_parallel_calls() {
        let chunks: Vec<reqwest::Result<Bytes>> = vec![Ok(Bytes::from_static(
            b"{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"function\":{\"name\":\"first\",\"arguments\":{\"x\":1}}}]},\"done\":false}\n\
              {\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"function\":{\"name\":\"second\",\"arguments\":{\"y\":2}}}]},\"done\":false}\n\
              {\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\"}\n",
        ))];

        let deltas: Vec<ToolStreamDelta> = collect_tool_deltas(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();

        assert_eq!(deltas.len(), 1);
        let calls = deltas[0].tool_calls.as_ref().expect("tool calls");
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].function.name, "first");
        assert_eq!(calls[1].function.name, "second");
        assert!(deltas[0].done);
    }

    #[tokio::test]
    async fn ndjson_tool_stream_keeps_terminal_content() {
        let chunks: Vec<reqwest::Result<Bytes>> = vec![Ok(Bytes::from_static(
            b"{\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}\n\
              {\"message\":{\"role\":\"assistant\",\"content\":\" world\"},\"done\":true,\"done_reason\":\"stop\"}\n",
        ))];

        let deltas: Vec<ToolStreamDelta> = collect_tool_deltas(chunks)
            .await
            .into_iter()
            .map(|r| r.unwrap())
            .collect();

        assert_eq!(deltas.len(), 2);
        assert_eq!(deltas[0].content, "Hello");
        assert_eq!(deltas[1].content, " world");
        assert!(deltas[1].done);
    }

    #[tokio::test]
    async fn ndjson_surfaces_malformed_line_as_error() {
        let chunks = vec![Ok(Bytes::from_static(b"{not json}\n"))];
        let first = collect(chunks).await.into_iter().next().expect("one item");
        assert!(matches!(first, Err(AppError::UpstreamError(_))));
    }

    #[tokio::test]
    async fn model_metadata_surfaces_non_success_show_status() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(ResponseTemplate::new(404).set_body_json(json!({
                "error": "missing model"
            })))
            .mount(&server)
            .await;
        let client = OllamaClient::new(
            reqwest::Client::new(),
            Url::parse(&server.uri()).expect("mock server URL"),
        );

        let err = client
            .model_metadata("missing")
            .await
            .expect_err("non-2xx /api/show should fail");

        match err {
            AppError::UpstreamError(message) => {
                assert!(message.contains("404"), "status should be preserved");
                assert!(
                    message.contains("missing model"),
                    "response body should be preserved"
                );
            }
            other => panic!("expected UpstreamError, got {other:?}"),
        }
    }

    fn chat_response() -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(json!({
            "message": {"role": "assistant", "content": "hi"},
            "done": true,
        }))
    }

    /// Client pointed at the mock server. Layer setters on the binding when a
    /// test needs num_ctx injection or retries.
    fn test_client(server: &MockServer) -> OllamaClient {
        OllamaClient::new(
            reqwest::Client::new(),
            Url::parse(&server.uri()).expect("mock server URL"),
        )
    }

    fn fast_retry() -> super::RetryPolicy {
        super::RetryPolicy {
            max_retries: 3,
            network_max_retries: 2,
            initial: std::time::Duration::from_millis(1),
            multiplier: 1.0,
            cap: std::time::Duration::from_millis(1),
        }
    }

    #[tokio::test]
    async fn chat_once_retries_500_until_the_model_is_loaded() {
        let server = MockServer::start().await;
        // Two load-window 500s, then success — first-mounted match wins until
        // its budget is spent.
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(500).set_body_string("model is loading"))
            .up_to_n_times(2)
            .expect(2)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(chat_response())
            .expect(1)
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        client.set_retry_policy(fast_retry());

        let message = crate::ollama::ChatBackend::chat_once(&client, "big", &[], &[], &Map::new())
            .await
            .expect("succeeds after transient 500s");
        assert!(matches!(
            message.content,
            Some(crate::openai::types::MessageContent::Text(t)) if t == "hi"
        ));
    }

    #[tokio::test]
    async fn five_xx_budget_is_independent_of_the_network_budget() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(500).set_body_string("loading"))
            .up_to_n_times(2)
            .expect(2)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(chat_response())
            .expect(1)
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        // Zero network budget: two 500s must still be retried on the 5xx
        // budget (per-class counters, not one shared count).
        client.set_retry_policy(super::RetryPolicy {
            network_max_retries: 0,
            ..fast_retry()
        });

        crate::ollama::ChatBackend::chat_once(&client, "big", &[], &[], &Map::new())
            .await
            .expect("5xx retries unaffected by the network budget");
    }

    #[tokio::test]
    async fn chat_once_gives_up_when_retries_are_exhausted() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(500).set_body_string("still broken"))
            .expect(4) // initial attempt + max_retries(3)
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        client.set_retry_policy(fast_retry());

        let err = crate::ollama::ChatBackend::chat_once(&client, "big", &[], &[], &Map::new())
            .await
            .expect_err("permanent 500 eventually surfaces");
        assert!(matches!(err, AppError::UpstreamError(m) if m.contains("still broken")));
    }

    #[tokio::test]
    async fn chat_once_does_not_retry_client_errors() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(404).set_body_string("model not found"))
            .expect(1) // a 4xx must never be retried
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        client.set_retry_policy(fast_retry());

        let err = crate::ollama::ChatBackend::chat_once(&client, "m", &[], &[], &Map::new())
            .await
            .expect_err("404 is a real error");
        assert!(matches!(err, AppError::UpstreamError(m) if m.contains("model not found")));
    }

    #[tokio::test]
    async fn warm_model_does_not_retry() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(500).set_body_string("loading"))
            .expect(1) // warm is fast best-effort: exactly one attempt
            .mount(&server)
            .await;
        let mut client = test_client(&server);
        client.set_retry_policy(fast_retry());

        client.warm_model("big").await.expect_err("fails fast");
    }

    #[tokio::test]
    async fn permanent_500_bodies_are_not_retried() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(
                ResponseTemplate::new(500)
                    .set_body_string("model requires more system memory (32 GiB)"),
            )
            .expect(1) // deterministic failure: retrying can never succeed
            .mount(&server)
            .await;
        let mut client = test_client(&server);
        client.set_retry_policy(fast_retry());

        let err = crate::ollama::ChatBackend::chat_once(&client, "big", &[], &[], &Map::new())
            .await
            .expect_err("permanent 500 surfaces immediately");
        assert!(matches!(err, AppError::UpstreamError(m) if m.contains("more system memory")));
    }

    #[test]
    fn retry_policy_backoff_is_exponential_and_capped() {
        let policy = super::RetryPolicy::default();
        assert_eq!(policy.delay(1), std::time::Duration::from_millis(2000));
        assert_eq!(policy.delay(2), std::time::Duration::from_millis(3000));
        assert_eq!(policy.delay(3), std::time::Duration::from_millis(4500));
        assert_eq!(
            policy.delay(20),
            std::time::Duration::from_secs(15),
            "capped"
        );
    }

    #[test]
    fn build_request_translates_max_tokens_to_num_predict() {
        let client = OllamaClient::new(
            reqwest::Client::new(),
            Url::parse("http://localhost:11434").unwrap(),
        );
        let options = Map::from_iter([("max_tokens".into(), json!(4096))]);
        let req = client.build_request("m", &[], &[], options, true, None);
        let opts = req.options.expect("options");
        assert_eq!(opts["num_predict"], 4096);
        assert!(opts.get("max_tokens").is_none());
    }

    #[test]
    fn build_request_prefers_max_completion_tokens_and_explicit_num_predict() {
        let client = OllamaClient::new(
            reqwest::Client::new(),
            Url::parse("http://localhost:11434").unwrap(),
        );
        // max_completion_tokens (reasoning models) wins over max_tokens, and
        // BOTH OpenAI names are stripped — a leftover would reach /api/chat
        // as an unknown option.
        let options = Map::from_iter([
            ("max_tokens".into(), json!(4096)),
            ("max_completion_tokens".into(), json!(1024)),
        ]);
        let req = client.build_request("m", &[], &[], options, true, None);
        let opts = req.options.expect("options");
        assert_eq!(opts["num_predict"], 1024);
        assert!(opts.get("max_tokens").is_none());
        assert!(opts.get("max_completion_tokens").is_none());

        // An explicit native num_predict wins over both.
        let options = Map::from_iter([
            ("max_tokens".into(), json!(4096)),
            ("num_predict".into(), json!(64)),
        ]);
        let req = client.build_request("m", &[], &[], options, true, None);
        let opts = req.options.expect("options");
        assert_eq!(opts["num_predict"], 64);
        assert!(opts.get("max_tokens").is_none());
    }

    fn show_response(model_info: Value) -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(json!({
            "capabilities": ["completion"],
            "model_info": model_info,
        }))
    }

    async fn chat_bodies(server: &MockServer) -> Vec<Value> {
        server
            .received_requests()
            .await
            .expect("requests recorded")
            .iter()
            .filter(|r| r.url.path() == "/api/chat")
            .map(|r| serde_json::from_slice(&r.body).expect("chat body is JSON"))
            .collect()
    }

    #[tokio::test]
    async fn chat_once_injects_capped_num_ctx_and_caches_metadata() {
        let server = MockServer::start().await;
        // Metadata is fetched once per model, not once per request.
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(show_response(json!({"qwen3.context_length": 40_960})))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(chat_response())
            .expect(2)
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        client.set_num_ctx_cap(32_768);
        for _ in 0..2 {
            crate::ollama::ChatBackend::chat_once(&client, "qwen3", &[], &[], &Map::new())
                .await
                .expect("chat");
        }

        for body in chat_bodies(&server).await {
            assert_eq!(body["options"]["num_ctx"], 32_768, "declared 40960 capped");
        }
    }

    #[tokio::test]
    async fn num_ctx_uses_declared_length_when_below_cap() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(show_response(json!({"tiny.context_length": 8192})))
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        client.set_num_ctx_cap(32_768);

        assert_eq!(
            client.resolve_num_ctx("tiny", &Map::new()).await,
            Some(8192)
        );
    }

    #[tokio::test]
    async fn request_supplied_num_ctx_wins_without_a_metadata_fetch() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(show_response(json!({"qwen3.context_length": 40_960})))
            .expect(0)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(chat_response())
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        client.set_num_ctx_cap(32_768);
        let options = Map::from_iter([("num_ctx".into(), json!(2048))]);
        crate::ollama::ChatBackend::chat_once(&client, "qwen3", &[], &[], &options)
            .await
            .expect("chat");

        assert_eq!(chat_bodies(&server).await[0]["options"]["num_ctx"], 2048);
    }

    #[tokio::test]
    async fn num_ctx_injection_disabled_by_default_and_without_declared_length() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(show_response(json!({"m.embedding_length": 5120})))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(chat_response())
            .mount(&server)
            .await;

        // Cap unset (0) => no injection and no metadata fetch.
        let client = test_client(&server);
        crate::ollama::ChatBackend::chat_once(&client, "m", &[], &[], &Map::new())
            .await
            .expect("chat");

        // Cap set but metadata reports no context length => keep Ollama's default.
        let mut capped = client.clone();
        capped.set_num_ctx_cap(32_768);
        crate::ollama::ChatBackend::chat_once(&capped, "m", &[], &[], &Map::new())
            .await
            .expect("chat");

        for body in chat_bodies(&server).await {
            assert!(body.get("options").is_none(), "no options injected: {body}");
        }
    }

    #[tokio::test]
    async fn failed_ctx_probe_is_retried_after_the_cooldown() {
        let server = MockServer::start().await;
        // First /api/show attempt fails; after the (zeroed) cooldown the next
        // call probes again and succeeds — a boot-window miss must not
        // disable num_ctx injection until restart.
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(ResponseTemplate::new(500).set_body_string("booting"))
            .up_to_n_times(1)
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(show_response(json!({"qwen3.context_length": 40_960})))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(chat_response())
            .expect(2)
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        client.set_num_ctx_cap(32_768);
        client.set_ctx_probe_cooldown(std::time::Duration::ZERO);

        for _ in 0..2 {
            crate::ollama::ChatBackend::chat_once(&client, "qwen3", &[], &[], &Map::new())
                .await
                .expect("chat");
        }

        let bodies = chat_bodies(&server).await;
        assert!(
            bodies[0].get("options").is_none(),
            "first chat: probe failed, no injection"
        );
        assert_eq!(
            bodies[1]["options"]["num_ctx"], 32_768,
            "second chat: cooldown elapsed, probe retried, injection active"
        );
    }

    #[tokio::test]
    async fn seeded_context_length_skips_the_lazy_probe() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/show"))
            .respond_with(show_response(json!({"qwen3.context_length": 40_960})))
            .expect(0) // seeded: the lazy probe must not fire
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(chat_response())
            .mount(&server)
            .await;

        let mut client = test_client(&server);
        client.set_num_ctx_cap(32_768);
        client.seed_context_length("qwen3", Some(40_960));

        crate::ollama::ChatBackend::chat_once(&client, "qwen3", &[], &[], &Map::new())
            .await
            .expect("chat");

        assert_eq!(chat_bodies(&server).await[0]["options"]["num_ctx"], 32_768);
    }

    #[test]
    fn reasoning_effort_none_maps_to_think_false() {
        let mut options = Map::from_iter([
            ("reasoning_effort".into(), Value::String("none".into())),
            ("temperature".into(), json!(0.2)),
        ]);

        assert_eq!(extract_thinking_control(&mut options), Some(false));
        assert!(!options.contains_key("reasoning_effort"));
        assert_eq!(options.get("temperature"), Some(&json!(0.2)));
    }

    #[test]
    fn reasoning_effort_value_maps_to_think_true() {
        let mut options = Map::from_iter([
            ("reasoning_effort".into(), Value::String("medium".into())),
            ("temperature".into(), json!(0.2)),
        ]);

        assert_eq!(extract_thinking_control(&mut options), Some(true));
        assert!(!options.contains_key("reasoning_effort"));
        assert_eq!(options.get("temperature"), Some(&json!(0.2)));
    }

    #[test]
    fn nested_reasoning_none_maps_to_think_false() {
        let mut options = Map::from_iter([("reasoning".into(), json!({ "effort": "none" }))]);

        assert_eq!(extract_thinking_control(&mut options), Some(false));
        assert!(!options.contains_key("reasoning"));
    }

    #[test]
    fn nested_reasoning_value_maps_to_think_true() {
        let mut options = Map::from_iter([("reasoning".into(), json!({ "effort": "medium" }))]);

        assert_eq!(extract_thinking_control(&mut options), Some(true));
        assert!(!options.contains_key("reasoning"));
    }
}
