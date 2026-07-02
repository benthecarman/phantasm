//! In-memory metrics registry: the hot-path tier of the two-tier observability
//! design (the durable tier is `metrics_store`, SQLite). Everything here is
//! atomics behind `Arc` — increments are lock-free after one brief map lock to
//! fetch the per-model/per-tool stats handle.
//!
//! This registry is the sole source for `GET /metrics` (Prometheus text
//! exposition). Counters are since-process-start by design; Prometheus detects
//! counter resets natively, and the dashboard reads durable history from the
//! store instead. Per NFR-O7 nothing in here ever holds message content —
//! model names, tool names, counts, and durations only.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::metrics_store::{MetricEvent, StoreHandle};

/// Monotonic counter.
#[derive(Default)]
pub struct Counter(AtomicU64);

impl Counter {
    pub fn inc(&self) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
    pub fn add(&self, n: u64) {
        self.0.fetch_add(n, Ordering::Relaxed);
    }
    pub fn get(&self) -> u64 {
        self.0.load(Ordering::Relaxed)
    }
}

/// Up/down gauge (e.g. currently-active turns).
#[derive(Default)]
pub struct Gauge(AtomicI64);

impl Gauge {
    pub fn inc(&self) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
    pub fn dec(&self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
    pub fn get(&self) -> i64 {
        self.0.load(Ordering::Relaxed)
    }
}

/// Upper bounds (seconds) for turn/phase/tool durations.
pub const DURATION_BOUNDS: &[f64] = &[
    0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0, 600.0,
];
/// Upper bounds (seconds) for time-to-first-token.
pub const TTFT_BOUNDS: &[f64] = &[0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0];
/// Upper bounds (tokens/second) for generation throughput.
pub const TOKENS_PER_SEC_BOUNDS: &[f64] = &[1.0, 2.0, 5.0, 10.0, 20.0, 40.0, 80.0, 160.0, 320.0];

/// Fixed-bucket histogram. Buckets store per-bucket (non-cumulative) counts;
/// the sum is kept in integer microseconds to stay on `AtomicU64`.
pub struct Histogram {
    bounds: &'static [f64],
    buckets: Box<[AtomicU64]>, // bounds.len() + 1 (last = +Inf overflow)
    sum_micros: AtomicU64,
    count: AtomicU64,
}

impl Histogram {
    pub fn new(bounds: &'static [f64]) -> Self {
        let buckets = (0..=bounds.len()).map(|_| AtomicU64::new(0)).collect();
        Histogram {
            bounds,
            buckets,
            sum_micros: AtomicU64::new(0),
            count: AtomicU64::new(0),
        }
    }

    /// Record one observation (seconds for durations, or the metric's unit).
    pub fn observe(&self, v: f64) {
        let idx = self
            .bounds
            .iter()
            .position(|b| v <= *b)
            .unwrap_or(self.bounds.len());
        self.buckets[idx].fetch_add(1, Ordering::Relaxed);
        self.sum_micros
            .fetch_add((v.max(0.0) * 1e6) as u64, Ordering::Relaxed);
        self.count.fetch_add(1, Ordering::Relaxed);
    }

    pub fn observe_duration(&self, d: Duration) {
        self.observe(d.as_secs_f64());
    }

    pub fn snapshot(&self) -> HistogramSnapshot {
        let mut cumulative = Vec::with_capacity(self.buckets.len());
        let mut acc = 0u64;
        for b in self.buckets.iter() {
            acc += b.load(Ordering::Relaxed);
            cumulative.push(acc);
        }
        HistogramSnapshot {
            bounds: self.bounds,
            cumulative,
            sum: self.sum_micros.load(Ordering::Relaxed) as f64 / 1e6,
            count: self.count.load(Ordering::Relaxed),
        }
    }
}

/// Point-in-time histogram view. `cumulative[i]` is the count of observations
/// `<= bounds[i]`; the final entry is the +Inf bucket (== `count`).
pub struct HistogramSnapshot {
    pub bounds: &'static [f64],
    pub cumulative: Vec<u64>,
    pub sum: f64,
    pub count: u64,
}

/// Turn/token metrics for one upstream model. Cardinality is naturally
/// bounded by the user's installed model list.
pub struct ModelStats {
    pub turns_started: Counter,
    pub turns_completed: Counter,
    pub turns_errored: Counter,
    pub turns_cancelled: Counter,
    pub turns_plain: Counter,
    pub turns_with_tools: Counter,
    pub turn_cap_hits: Counter,
    pub turn_duration: Histogram,
    pub turn_ttft: Histogram,
    pub resolution_phase: Histogram,
    pub streaming_phase: Histogram,
    pub prompt_tokens: Counter,
    pub completion_tokens: Counter,
    pub tokens_per_sec: Histogram,
    pub model_load: Histogram,
}

impl ModelStats {
    fn new() -> Self {
        ModelStats {
            turns_started: Counter::default(),
            turns_completed: Counter::default(),
            turns_errored: Counter::default(),
            turns_cancelled: Counter::default(),
            turns_plain: Counter::default(),
            turns_with_tools: Counter::default(),
            turn_cap_hits: Counter::default(),
            turn_duration: Histogram::new(DURATION_BOUNDS),
            turn_ttft: Histogram::new(TTFT_BOUNDS),
            resolution_phase: Histogram::new(DURATION_BOUNDS),
            streaming_phase: Histogram::new(DURATION_BOUNDS),
            prompt_tokens: Counter::default(),
            completion_tokens: Counter::default(),
            tokens_per_sec: Histogram::new(TOKENS_PER_SEC_BOUNDS),
            model_load: Histogram::new(DURATION_BOUNDS),
        }
    }
}

/// Call/error/latency stats for one server-side tool.
pub struct ToolStats {
    pub calls: Counter,
    pub errors: Counter,
    pub duration: Histogram,
}

impl ToolStats {
    fn new() -> Self {
        ToolStats {
            calls: Counter::default(),
            errors: Counter::default(),
            duration: Histogram::new(DURATION_BOUNDS),
        }
    }
}

/// How a turn ended, from the event forwarder's point of view. A producer
/// channel that closes without a terminal `Done`/`Error` event is the existing
/// "cancelled" semantic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnOutcome {
    Completed,
    Errored,
    Cancelled,
}

impl TurnOutcome {
    pub fn as_str(self) -> &'static str {
        match self {
            TurnOutcome::Completed => "completed",
            TurnOutcome::Errored => "errored",
            TurnOutcome::Cancelled => "cancelled",
        }
    }
}

/// The registry. One per process, shared via `AppState`.
pub struct Metrics {
    pub started_at: Instant,
    models: Mutex<HashMap<String, Arc<ModelStats>>>,
    tools: Mutex<HashMap<String, Arc<ToolStats>>>,
    pub turns_active: Gauge,
    pub images_generated: Counter,
    pub http_unauthorized: Counter,
    pub sse_disconnects: Counter,
    store: Option<StoreHandle>,
}

impl Metrics {
    pub fn new(store: Option<StoreHandle>) -> Arc<Self> {
        Arc::new(Metrics {
            started_at: Instant::now(),
            models: Mutex::new(HashMap::new()),
            tools: Mutex::new(HashMap::new()),
            turns_active: Gauge::default(),
            images_generated: Counter::default(),
            http_unauthorized: Counter::default(),
            sse_disconnects: Counter::default(),
            store,
        })
    }

    /// Memory-only registry for tests.
    pub fn without_store() -> Arc<Self> {
        Metrics::new(None)
    }

    pub fn model(&self, name: &str) -> Arc<ModelStats> {
        let mut map = self.models.lock().unwrap();
        if let Some(stats) = map.get(name) {
            return stats.clone();
        }
        let stats = Arc::new(ModelStats::new());
        map.insert(name.to_string(), stats.clone());
        stats
    }

    /// `known` is decided by the tool registry's dispatch match; anything the
    /// model invented (or a disabled tool) buckets under `"other"` so label
    /// cardinality stays bounded.
    pub fn tool(&self, name: &str, known: bool) -> Arc<ToolStats> {
        let key = if known { name } else { "other" };
        let mut map = self.tools.lock().unwrap();
        if let Some(stats) = map.get(key) {
            return stats.clone();
        }
        let stats = Arc::new(ToolStats::new());
        map.insert(key.to_string(), stats.clone());
        stats
    }

    fn send(&self, ev: MetricEvent) {
        if let Some(store) = &self.store {
            store.send(ev);
        }
    }

    /// The durable history store behind this registry, when one is configured.
    /// The dashboard uses it to open read connections.
    pub fn store(&self) -> Option<&StoreHandle> {
        self.store.as_ref()
    }

    pub fn record_turn_started(&self, model: &str) {
        self.model(model).turns_started.inc();
        self.turns_active.inc();
    }

    #[allow(clippy::too_many_arguments)]
    pub fn record_turn_finished(
        &self,
        model: &str,
        mode: Option<&str>,
        outcome: TurnOutcome,
        total: Duration,
        ttft: Option<Duration>,
        used_tools: bool,
    ) {
        let stats = self.model(model);
        match outcome {
            TurnOutcome::Completed => stats.turns_completed.inc(),
            TurnOutcome::Errored => stats.turns_errored.inc(),
            TurnOutcome::Cancelled => stats.turns_cancelled.inc(),
        }
        stats.turn_duration.observe_duration(total);
        if let Some(t) = ttft {
            stats.turn_ttft.observe_duration(t);
        }
        self.turns_active.dec();
        self.send(MetricEvent::Turn {
            model: model.to_string(),
            mode: mode.map(str::to_string),
            outcome,
            duration_ms: total.as_millis() as u64,
            ttft_ms: ttft.map(|t| t.as_millis() as u64),
            used_tools,
        });
    }

    pub fn record_tool_call(
        &self,
        tool: &str,
        known: bool,
        model: &str,
        dur: Duration,
        is_error: bool,
    ) {
        let stats = self.tool(tool, known);
        stats.calls.inc();
        if is_error {
            stats.errors.inc();
        } else if matches!(tool, "image_generation" | "image_edit") {
            self.images_generated.inc();
        }
        stats.duration.observe_duration(dur);
        self.send(MetricEvent::ToolCall {
            tool: if known { tool } else { "other" }.to_string(),
            model: model.to_string(),
            ok: !is_error,
            duration_ms: dur.as_millis() as u64,
        });
    }

    /// Record upstream token usage. All fields optional: the OpenAI-compat
    /// upstream reports token counts but not Ollama's nanosecond timings.
    pub fn record_usage(
        &self,
        model: &str,
        prompt_tokens: Option<u64>,
        completion_tokens: Option<u64>,
        eval_duration_ns: Option<u64>,
        load_duration_ns: Option<u64>,
    ) {
        if prompt_tokens.is_none() && completion_tokens.is_none() {
            return;
        }
        let stats = self.model(model);
        if let Some(p) = prompt_tokens {
            stats.prompt_tokens.add(p);
        }
        if let Some(c) = completion_tokens {
            stats.completion_tokens.add(c);
        }
        let tokens_per_sec = match (completion_tokens, eval_duration_ns) {
            (Some(c), Some(ns)) if ns > 0 && c > 0 => {
                let tps = c as f64 / (ns as f64 / 1e9);
                stats.tokens_per_sec.observe(tps);
                Some(tps)
            }
            _ => None,
        };
        if let Some(ns) = load_duration_ns.filter(|ns| *ns > 0) {
            stats.model_load.observe(ns as f64 / 1e9);
        }
        self.send(MetricEvent::Usage {
            model: model.to_string(),
            prompt_tokens,
            completion_tokens,
            tokens_per_sec,
            load_ms: load_duration_ns.map(|ns| ns / 1_000_000),
        });
    }

    /// Sorted snapshots for deterministic rendering.
    pub fn models_snapshot(&self) -> Vec<(String, Arc<ModelStats>)> {
        let mut v: Vec<_> = self
            .models
            .lock()
            .unwrap()
            .iter()
            .map(|(k, s)| (k.clone(), s.clone()))
            .collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    }

    pub fn tools_snapshot(&self) -> Vec<(String, Arc<ToolStats>)> {
        let mut v: Vec<_> = self
            .tools
            .lock()
            .unwrap()
            .iter()
            .map(|(k, s)| (k.clone(), s.clone()))
            .collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    }
}

/// Per-turn recording context handed to `run_turn`. `used_tools` is shared
/// with the event forwarder in `routes::chat`, which writes the durable turn
/// row at completion — the loop body is the only place that knows whether the
/// turn actually entered tool resolution.
#[derive(Clone)]
pub struct TurnRecorder {
    pub metrics: Arc<Metrics>,
    pub used_tools: Arc<AtomicBool>,
}

impl TurnRecorder {
    pub fn new(metrics: Arc<Metrics>) -> Self {
        TurnRecorder {
            metrics,
            used_tools: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn mark_used_tools(&self) {
        self.used_tools.store(true, Ordering::Relaxed);
    }

    pub fn used_tools(&self) -> bool {
        self.used_tools.load(Ordering::Relaxed)
    }
}

/// Values computed at scrape time rather than stored (registry state,
/// semaphore occupancy, uptime).
pub struct LiveGauges {
    pub registry_running: u64,
    pub registry_attached: u64,
    pub registry_detached_running: u64,
    pub registry_buffered: u64,
    pub upstream_inflight: u64,
    pub upstream_max: u64,
    pub uptime_seconds: u64,
    pub version: &'static str,
}

/// Escape a label value per the Prometheus text exposition format.
fn escape_label(v: &str) -> String {
    v.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

struct PromWriter(String);

impl PromWriter {
    fn header(&mut self, name: &str, kind: &str, help: &str) {
        self.0
            .push_str(&format!("# HELP {name} {help}\n# TYPE {name} {kind}\n"));
    }

    fn value(&mut self, name: &str, labels: &[(&str, &str)], v: impl std::fmt::Display) {
        self.0.push_str(name);
        if !labels.is_empty() {
            self.0.push('{');
            for (i, (k, val)) in labels.iter().enumerate() {
                if i > 0 {
                    self.0.push(',');
                }
                self.0.push_str(&format!("{k}=\"{}\"", escape_label(val)));
            }
            self.0.push('}');
        }
        self.0.push_str(&format!(" {v}\n"));
    }

    fn histogram(&mut self, name: &str, labels: &[(&str, &str)], snap: &HistogramSnapshot) {
        let bucket_name = format!("{name}_bucket");
        for (i, cum) in snap.cumulative.iter().enumerate() {
            let le = snap
                .bounds
                .get(i)
                .map(|b| trim_float(*b))
                .unwrap_or_else(|| "+Inf".to_string());
            let mut ls: Vec<(&str, &str)> = labels.to_vec();
            ls.push(("le", &le));
            self.value(&bucket_name, &ls, cum);
        }
        self.value(&format!("{name}_sum"), labels, trim_float(snap.sum));
        self.value(&format!("{name}_count"), labels, snap.count);
    }
}

/// Render `0.25` not `0.250000`, `5` not `5.0` — matches conventional
/// exposition output and keeps the text compact.
fn trim_float(v: f64) -> String {
    if v.fract() == 0.0 && v.abs() < 1e15 {
        format!("{}", v as i64)
    } else {
        format!("{v}")
    }
}

/// One rendered metric column: (name, help, accessor into `ModelStats`).
type CounterCol = (&'static str, &'static str, fn(&ModelStats) -> u64);
type HistogramCol = (
    &'static str,
    &'static str,
    fn(&ModelStats) -> HistogramSnapshot,
);

pub fn render_prometheus(m: &Metrics, live: &LiveGauges) -> String {
    let mut w = PromWriter(String::with_capacity(8192));
    let models = m.models_snapshot();
    let tools = m.tools_snapshot();

    // Per-model counters. Aggregate = sum() in PromQL; no unlabeled duplicates.
    let counters: [CounterCol; 7] = [
        ("phantasm_turns_started_total", "Turns started", |s| {
            s.turns_started.get()
        }),
        (
            "phantasm_turns_completed_total",
            "Turns finished cleanly",
            |s| s.turns_completed.get(),
        ),
        (
            "phantasm_turns_errored_total",
            "Turns ended by an error",
            |s| s.turns_errored.get(),
        ),
        (
            "phantasm_turns_cancelled_total",
            "Turns cancelled before a terminal event",
            |s| s.turns_cancelled.get(),
        ),
        (
            "phantasm_turns_plain_total",
            "Turns that skipped tool resolution",
            |s| s.turns_plain.get(),
        ),
        (
            "phantasm_turns_with_tools_total",
            "Turns that entered the tool loop",
            |s| s.turns_with_tools.get(),
        ),
        (
            "phantasm_turn_cap_hits_total",
            "Turns that hit MAX_TOOL_ITERS",
            |s| s.turn_cap_hits.get(),
        ),
    ];
    for (name, help, get) in counters {
        w.header(name, "counter", help);
        for (model, stats) in &models {
            w.value(name, &[("model", model)], get(stats));
        }
    }

    let token_counters: [CounterCol; 2] = [
        (
            "phantasm_prompt_tokens_total",
            "Prompt tokens reported by the upstream",
            |s| s.prompt_tokens.get(),
        ),
        (
            "phantasm_completion_tokens_total",
            "Completion tokens reported by the upstream",
            |s| s.completion_tokens.get(),
        ),
    ];
    for (name, help, get) in token_counters {
        w.header(name, "counter", help);
        for (model, stats) in &models {
            w.value(name, &[("model", model)], get(stats));
        }
    }

    let histograms: [HistogramCol; 6] = [
        (
            "phantasm_turn_duration_seconds",
            "End-to-end turn duration",
            |s| s.turn_duration.snapshot(),
        ),
        (
            "phantasm_turn_ttft_seconds",
            "Time to first streamed token",
            |s| s.turn_ttft.snapshot(),
        ),
        (
            "phantasm_turn_resolution_phase_seconds",
            "Tool-resolution phase duration",
            |s| s.resolution_phase.snapshot(),
        ),
        (
            "phantasm_turn_streaming_phase_seconds",
            "Final streaming phase duration",
            |s| s.streaming_phase.snapshot(),
        ),
        (
            "phantasm_generation_tokens_per_second",
            "Upstream generation throughput",
            |s| s.tokens_per_sec.snapshot(),
        ),
        (
            "phantasm_model_load_seconds",
            "Upstream model load time when a cold load happened",
            |s| s.model_load.snapshot(),
        ),
    ];
    for (name, help, get) in histograms {
        w.header(name, "histogram", help);
        for (model, stats) in &models {
            w.histogram(name, &[("model", model)], &get(stats));
        }
    }

    // Per-tool series.
    w.header("phantasm_tool_calls_total", "counter", "Tool invocations");
    for (tool, stats) in &tools {
        w.value(
            "phantasm_tool_calls_total",
            &[("tool", tool)],
            stats.calls.get(),
        );
    }
    w.header(
        "phantasm_tool_errors_total",
        "counter",
        "Tool invocations that returned an error",
    );
    for (tool, stats) in &tools {
        w.value(
            "phantasm_tool_errors_total",
            &[("tool", tool)],
            stats.errors.get(),
        );
    }
    w.header(
        "phantasm_tool_duration_seconds",
        "histogram",
        "Tool invocation duration",
    );
    for (tool, stats) in &tools {
        w.histogram(
            "phantasm_tool_duration_seconds",
            &[("tool", tool)],
            &stats.duration.snapshot(),
        );
    }

    // Global, unlabeled.
    w.header(
        "phantasm_turns_active",
        "gauge",
        "Turns currently executing",
    );
    w.value("phantasm_turns_active", &[], m.turns_active.get());
    w.header(
        "phantasm_images_generated_total",
        "counter",
        "Images generated or edited successfully",
    );
    w.value(
        "phantasm_images_generated_total",
        &[],
        m.images_generated.get(),
    );
    w.header(
        "phantasm_http_unauthorized_total",
        "counter",
        "Requests rejected by bearer auth",
    );
    w.value(
        "phantasm_http_unauthorized_total",
        &[],
        m.http_unauthorized.get(),
    );
    w.header(
        "phantasm_sse_disconnects_total",
        "counter",
        "Clients that dropped mid-stream",
    );
    w.value(
        "phantasm_sse_disconnects_total",
        &[],
        m.sse_disconnects.get(),
    );

    w.header(
        "phantasm_turn_registry_running",
        "gauge",
        "Buffered turns still executing",
    );
    w.value("phantasm_turn_registry_running", &[], live.registry_running);
    w.header(
        "phantasm_turn_registry_attached",
        "gauge",
        "Responders currently attached to buffered turns",
    );
    w.value(
        "phantasm_turn_registry_attached",
        &[],
        live.registry_attached,
    );
    w.header(
        "phantasm_turn_registry_detached_running",
        "gauge",
        "Running buffered turns with no attached responder",
    );
    w.value(
        "phantasm_turn_registry_detached_running",
        &[],
        live.registry_detached_running,
    );
    w.header(
        "phantasm_turn_registry_buffered",
        "gauge",
        "Terminal turns retained for replay",
    );
    w.value(
        "phantasm_turn_registry_buffered",
        &[],
        live.registry_buffered,
    );

    w.header(
        "phantasm_upstream_inflight",
        "gauge",
        "Upstream requests currently in flight",
    );
    w.value("phantasm_upstream_inflight", &[], live.upstream_inflight);
    w.header(
        "phantasm_upstream_max_concurrency",
        "gauge",
        "Configured upstream concurrency cap",
    );
    w.value("phantasm_upstream_max_concurrency", &[], live.upstream_max);

    w.header(
        "phantasm_uptime_seconds",
        "gauge",
        "Seconds since the orchestrator started",
    );
    w.value("phantasm_uptime_seconds", &[], live.uptime_seconds);
    w.header("phantasm_build_info", "gauge", "Build metadata");
    w.value("phantasm_build_info", &[("version", live.version)], 1);

    w.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn live() -> LiveGauges {
        LiveGauges {
            registry_running: 0,
            registry_attached: 0,
            registry_detached_running: 0,
            registry_buffered: 0,
            upstream_inflight: 1,
            upstream_max: 2,
            uptime_seconds: 42,
            version: "test",
        }
    }

    #[test]
    fn histogram_buckets_and_sum() {
        let h = Histogram::new(&[1.0, 5.0]);
        h.observe(0.5); // bucket 0
        h.observe(1.0); // bucket 0 (le is inclusive)
        h.observe(3.0); // bucket 1
        h.observe(100.0); // +Inf
        let snap = h.snapshot();
        assert_eq!(snap.cumulative, vec![2, 3, 4]);
        assert_eq!(snap.count, 4);
        assert!((snap.sum - 104.5).abs() < 1e-6);
    }

    #[test]
    fn tool_label_clamped_to_other() {
        let m = Metrics::without_store();
        m.record_tool_call("made_up_tool", false, "m1", Duration::from_millis(5), true);
        m.record_tool_call("web_search", true, "m1", Duration::from_millis(5), false);
        let tools = m.tools_snapshot();
        let names: Vec<_> = tools.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, vec!["other", "web_search"]);
        let other = &tools[0].1;
        assert_eq!(other.calls.get(), 1);
        assert_eq!(other.errors.get(), 1);
    }

    #[test]
    fn images_counter_bumps_on_successful_generation_only() {
        let m = Metrics::without_store();
        m.record_tool_call("image_generation", true, "m", Duration::from_secs(1), false);
        m.record_tool_call("image_generation", true, "m", Duration::from_secs(1), true);
        m.record_tool_call("image_edit", true, "m", Duration::from_secs(1), false);
        m.record_tool_call("web_search", true, "m", Duration::from_secs(1), false);
        assert_eq!(m.images_generated.get(), 2);
    }

    #[test]
    fn usage_records_tokens_and_throughput() {
        let m = Metrics::without_store();
        m.record_usage(
            "llama3",
            Some(100),
            Some(50),
            Some(2_000_000_000),
            Some(500_000_000),
        );
        let stats = m.model("llama3");
        assert_eq!(stats.prompt_tokens.get(), 100);
        assert_eq!(stats.completion_tokens.get(), 50);
        // 50 tokens / 2s = 25 tok/s → the 40-bound bucket.
        let tps = stats.tokens_per_sec.snapshot();
        assert_eq!(tps.count, 1);
        let load = stats.model_load.snapshot();
        assert_eq!(load.count, 1);
        // Absent usage records nothing.
        m.record_usage("llama3", None, None, None, None);
        assert_eq!(m.model("llama3").prompt_tokens.get(), 100);
    }

    #[test]
    fn turn_lifecycle_counters() {
        let m = Metrics::without_store();
        m.record_turn_started("m1");
        assert_eq!(m.turns_active.get(), 1);
        m.record_turn_finished(
            "m1",
            None,
            TurnOutcome::Completed,
            Duration::from_secs(2),
            Some(Duration::from_millis(300)),
            false,
        );
        assert_eq!(m.turns_active.get(), 0);
        let s = m.model("m1");
        assert_eq!(s.turns_completed.get(), 1);
        assert_eq!(s.turn_duration.snapshot().count, 1);
        assert_eq!(s.turn_ttft.snapshot().count, 1);
    }

    #[test]
    fn prometheus_render_shape() {
        let m = Metrics::without_store();
        m.record_turn_started("lla\"ma");
        m.record_turn_finished(
            "lla\"ma",
            None,
            TurnOutcome::Completed,
            Duration::from_secs(1),
            None,
            false,
        );
        m.record_tool_call(
            "web_search",
            true,
            "lla\"ma",
            Duration::from_millis(10),
            false,
        );
        let out = render_prometheus(&m, &live());
        assert!(out.contains("# TYPE phantasm_turns_started_total counter"));
        assert!(out.contains("phantasm_turns_started_total{model=\"lla\\\"ma\"} 1"));
        assert!(out
            .contains("phantasm_turn_duration_seconds_bucket{model=\"lla\\\"ma\",le=\"+Inf\"} 1"));
        assert!(out.contains("phantasm_tool_calls_total{tool=\"web_search\"} 1"));
        assert!(out.contains("phantasm_upstream_inflight 1"));
        assert!(out.contains("phantasm_build_info{version=\"test\"} 1"));
    }
}
