//! Buffered, resumable turns (see `docs/resilient-turns.md`).
//!
//! The orchestrator is otherwise stateless across requests (XR-2). Streaming
//! turns started with an `Idempotency-Key` are the exception: the turn task
//! keeps running regardless of whether a client is attached, appending its
//! `TurnEvent`s to an in-memory log here. A dropped connection (e.g. the app
//! backgrounding) no longer cancels the work — a reconnect with the same key
//! replays the log and tails live events to completion. Entries are TTL'd and
//! bounded; a miss degrades gracefully (the app re-issues the turn as new).

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use crate::orchestrator::TurnEvent;

/// One buffered turn: an append-only event log plus a `watch` channel carrying
/// the log length, so attached responders wake on every append (and on the
/// terminal event) without a lost-wakeup race — `watch::Receiver::changed`
/// tracks a version, so a send between a responder's snapshot and its await is
/// never missed.
pub struct ActiveTurn {
    inner: Mutex<TurnLog>,
    /// Current event count; bumped after each append. Responders
    /// `changed().await` on a clone to learn there is more to read.
    len_tx: watch::Sender<usize>,
    /// Cancels the turn task. Fired only by the explicit cancel endpoint or the
    /// TTL watchdog (neither in phase 1) — never by a client disconnect, which is
    /// the whole point: backgrounding detaches the responder but the turn runs on.
    pub cancel: CancellationToken,
    created_at: Instant,
    local_max_bytes: usize,
    budget: Arc<BufferBudget>,
}

struct TurnLog {
    events: Vec<TurnEvent>,
    /// Approximate encoded bytes held by `events`.
    buffered_bytes: usize,
    /// Portion of `buffered_bytes` reserved from the shared budget (the small
    /// terminal overflow error itself is deliberately allowed outside it).
    reserved_bytes: usize,
    /// Set once a terminal `Done`/`Error` is appended (or the producer's channel
    /// closes). Tells a responder to stop after draining.
    done: bool,
    /// When the turn reached a terminal state; drives result-TTL eviction.
    terminal_at: Option<Instant>,
    /// Number of responders currently attached (streaming the log).
    attached: usize,
    /// When `attached` last fell to 0 (or creation, before the first attach).
    /// `None` while a responder is attached. Drives the abandoned-turn watchdog:
    /// a still-running turn with no listener for too long is cancelled, so an app
    /// that was force-killed (never reconnects, never hits cancel) doesn't leave
    /// work running.
    detached_at: Option<Instant>,
}

impl ActiveTurn {
    fn new(cancel: CancellationToken, local_max_bytes: usize, budget: Arc<BufferBudget>) -> Self {
        let (len_tx, _) = watch::channel(0usize);
        ActiveTurn {
            inner: Mutex::new(TurnLog {
                events: Vec::new(),
                buffered_bytes: 0,
                reserved_bytes: 0,
                done: false,
                terminal_at: None,
                attached: 0,
                // No listener yet — counts as detached from creation, so a turn
                // whose only client vanishes before attaching is still swept.
                detached_at: Some(Instant::now()),
            }),
            len_tx,
            cancel,
            created_at: Instant::now(),
            local_max_bytes: local_max_bytes.max(1),
            budget,
        }
    }

    /// Register a newly attached responder. Clears the detached clock while at
    /// least one client is streaming.
    pub fn attach(&self) {
        let mut log = self.inner.lock().unwrap();
        log.attached += 1;
        log.detached_at = None;
    }

    /// Deregister a responder (its stream was dropped or finished). Restarts the
    /// detached clock once the last one leaves.
    pub fn detach(&self) {
        let mut log = self.inner.lock().unwrap();
        log.attached = log.attached.saturating_sub(1);
        if log.attached == 0 {
            log.detached_at = Some(Instant::now());
        }
    }

    /// Whether this turn is still running with no listener for longer than
    /// `grace` — i.e. abandoned and worth cancelling. Terminal turns are never
    /// abandoned (they're just buffered results awaiting a possible reconnect).
    fn is_abandoned(&self, grace: Duration) -> bool {
        let log = self.inner.lock().unwrap();
        !log.done && matches!(log.detached_at, Some(t) if t.elapsed() >= grace)
    }

    /// Append an event produced by the turn task, marking the turn terminal on a
    /// `Done`/`Error`, then wake attached responders.
    pub fn push(&self, event: TurnEvent) -> bool {
        let (len, accepted, overflowed) = {
            let mut log = self.inner.lock().unwrap();
            if log.done {
                return false;
            }
            let bytes = event_size(&event);
            if bytes > self.local_max_bytes.saturating_sub(log.buffered_bytes)
                || !self.budget.try_reserve(bytes)
            {
                let error = TurnEvent::Error(
                    "resumable turn buffer exceeded its configured byte limit".into(),
                );
                log.buffered_bytes = log.buffered_bytes.saturating_add(event_size(&error));
                log.events.push(error);
                log.done = true;
                log.terminal_at.get_or_insert_with(Instant::now);
                (log.events.len(), false, true)
            } else {
                log.buffered_bytes += bytes;
                log.reserved_bytes += bytes;
                if matches!(event, TurnEvent::Done { .. } | TurnEvent::Error(_)) {
                    log.done = true;
                    log.terminal_at.get_or_insert_with(Instant::now);
                }
                log.events.push(event);
                (log.events.len(), true, false)
            }
        };
        if overflowed {
            self.cancel.cancel();
        }
        // Bump the watch value so responders awaiting `changed()` wake.
        let _ = self.len_tx.send(len);
        accepted
    }

    /// Mark the turn finished without another event — used when the producer's
    /// channel closes without an explicit terminal (e.g. cancellation), so
    /// attached responders stop waiting rather than hang.
    pub fn finish(&self) {
        let len = {
            let mut log = self.inner.lock().unwrap();
            if !log.done {
                log.done = true;
                log.terminal_at.get_or_insert_with(Instant::now);
            }
            log.events.len()
        };
        let _ = self.len_tx.send(len);
    }

    /// Clone the events from `start` onward, plus whether the turn has finished.
    pub fn snapshot_from(&self, start: usize) -> (Vec<TurnEvent>, bool) {
        let log = self.inner.lock().unwrap();
        let from = start.min(log.events.len());
        (log.events[from..].to_vec(), log.done)
    }

    /// Clone the most recent logged event, if any. Lets a responder that has
    /// consumed the whole log (e.g. resuming past the terminal event via
    /// `Last-Event-ID`) still see how the turn ended.
    pub fn last_event(&self) -> Option<TurnEvent> {
        self.inner.lock().unwrap().events.last().cloned()
    }

    /// A receiver that fires when more events are available (or the turn ends).
    pub fn subscribe(&self) -> watch::Receiver<usize> {
        self.len_tx.subscribe()
    }

    fn is_terminal(&self) -> bool {
        self.inner.lock().unwrap().done
    }

    /// How long ago the turn reached a terminal state, if it has.
    fn terminal_age(&self) -> Option<Duration> {
        self.inner.lock().unwrap().terminal_at.map(|t| t.elapsed())
    }
}

impl Drop for ActiveTurn {
    fn drop(&mut self) {
        let reserved = self.inner.get_mut().unwrap().reserved_bytes;
        self.budget.release(reserved);
    }
}

struct BufferBudget {
    used: AtomicUsize,
    max: usize,
}

impl BufferBudget {
    fn new(max: usize) -> Self {
        Self {
            used: AtomicUsize::new(0),
            max: max.max(1),
        }
    }

    fn try_reserve(&self, bytes: usize) -> bool {
        self.used
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                used.checked_add(bytes).filter(|total| *total <= self.max)
            })
            .is_ok()
    }

    fn release(&self, bytes: usize) {
        self.used.fetch_sub(bytes, Ordering::AcqRel);
    }
}

fn event_size(event: &TurnEvent) -> usize {
    const OVERHEAD: usize = 32;
    OVERHEAD
        + match event {
            TurnEvent::Status(text)
            | TurnEvent::Reasoning(text)
            | TurnEvent::Token(text)
            | TurnEvent::Error(text) => text.len(),
            TurnEvent::Progress { status, .. } => status.len() + std::mem::size_of::<f64>(),
            TurnEvent::Throughput(_) => std::mem::size_of::<f64>(),
            TurnEvent::Done { reason } => reason.len(),
            TurnEvent::ToolCalls { app, held } => serde_json::to_vec(&(app, held))
                .map(|bytes| bytes.len())
                .unwrap_or(OVERHEAD),
        }
}

/// Counts reported by [`TurnRegistry::snapshot_counts`] for metrics.
#[derive(Debug, Default, Clone, Copy, serde::Serialize)]
pub struct RegistryCounts {
    /// Buffered turns still executing.
    pub running: u64,
    /// Responders currently attached across all turns.
    pub attached: u64,
    /// Running turns with no attached responder (backgrounded clients).
    pub detached_running: u64,
    /// Terminal turns retained for replay.
    pub buffered_terminal: u64,
    /// Approximate encoded event bytes retained across all turns.
    pub buffered_bytes: u64,
}

/// Store of buffered resumable turns, keyed by the client's `Idempotency-Key`.
#[derive(Clone)]
pub struct TurnRegistry {
    map: Arc<Mutex<HashMap<String, Arc<ActiveTurn>>>>,
    result_ttl: Duration,
    max: usize,
    per_turn_max_bytes: usize,
    budget: Arc<BufferBudget>,
}

impl TurnRegistry {
    pub fn new(
        result_ttl: Duration,
        max: usize,
        per_turn_max_bytes: usize,
        registry_max_bytes: usize,
    ) -> Self {
        TurnRegistry {
            map: Arc::new(Mutex::new(HashMap::new())),
            result_ttl,
            max: max.max(1),
            per_turn_max_bytes: per_turn_max_bytes.max(1),
            budget: Arc::new(BufferBudget::new(registry_max_bytes)),
        }
    }

    /// Get the turn for `key`, or create an empty one. Returns `(turn, is_new)`;
    /// when `is_new`, the caller must spawn the turn task + pump that fill it.
    /// Atomic under the lock so two concurrent requests with the same key can't
    /// both spawn — the second attaches to the first's (initially empty) log and
    /// waits for the pump to fill it. Purges expired/over-cap entries first.
    pub fn get_or_create(&self, key: &str) -> (Arc<ActiveTurn>, bool) {
        let mut map = self.map.lock().unwrap();
        self.purge(&mut map);
        if let Some(turn) = map.get(key) {
            return (turn.clone(), false);
        }
        let turn = Arc::new(ActiveTurn::new(
            CancellationToken::new(),
            self.per_turn_max_bytes,
            self.budget.clone(),
        ));
        map.insert(key.to_string(), turn.clone());
        (turn, true)
    }

    /// Look up a live turn without creating one (the cancel endpoint, phase 2).
    pub fn get(&self, key: &str) -> Option<Arc<ActiveTurn>> {
        self.map.lock().unwrap().get(key).cloned()
    }

    /// Point-in-time counts for metrics — one pass under the map lock.
    pub fn snapshot_counts(&self) -> RegistryCounts {
        let map = self.map.lock().unwrap();
        let mut counts = RegistryCounts::default();
        for turn in map.values() {
            let log = turn.inner.lock().unwrap();
            counts.buffered_bytes += log.buffered_bytes as u64;
            counts.attached += log.attached as u64;
            if log.done {
                counts.buffered_terminal += 1;
            } else {
                counts.running += 1;
                if log.attached == 0 {
                    counts.detached_running += 1;
                }
            }
        }
        counts
    }

    /// Drop a turn from the registry (e.g. after an explicit cancel).
    pub fn remove(&self, key: &str) -> Option<Arc<ActiveTurn>> {
        self.map.lock().unwrap().remove(key)
    }

    /// Cancel and drop every turn that is still running but has had no attached
    /// responder for longer than `grace` (the abandoned-turn watchdog). Returns
    /// how many were swept. Cancelling fires each turn's token, which interrupts
    /// in-flight tool work (incl. a running ComfyUI generation) so the GPU is
    /// freed promptly rather than after the per-tool timeout.
    pub fn sweep_abandoned(&self, grace: Duration) -> usize {
        let mut map = self.map.lock().unwrap();
        let abandoned: Vec<String> = map
            .iter()
            .filter(|(_, t)| t.is_abandoned(grace))
            .map(|(k, _)| k.clone())
            .collect();
        for key in &abandoned {
            if let Some(turn) = map.remove(key) {
                turn.cancel.cancel();
            }
        }
        abandoned.len()
    }

    /// Evict finished turns whose buffered result has outlived `result_ttl`,
    /// returning how many were dropped. Called periodically by the watchdog so the
    /// TTL is honored even on an idle server (otherwise eviction only happens when
    /// the next request triggers `get_or_create`).
    pub fn evict_expired(&self) -> usize {
        let mut map = self.map.lock().unwrap();
        let before = map.len();
        Self::drop_expired(&mut map, self.result_ttl);
        before - map.len()
    }

    /// Spawn the background maintenance task: every `interval`, evict result-TTL-
    /// expired finished turns and (when `grace` > 0) cancel turns abandoned for
    /// longer than `grace`. `grace` of 0 disables only the abandoned-turn sweep;
    /// TTL eviction still runs. `interval` must be non-zero. Runs for the process
    /// lifetime.
    pub fn spawn_watchdog(&self, grace: Duration, interval: Duration) {
        let registry = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(interval);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tick.tick().await;
                let expired = registry.evict_expired();
                let abandoned = if grace.is_zero() {
                    0
                } else {
                    registry.sweep_abandoned(grace)
                };
                if expired + abandoned > 0 {
                    tracing::info!(expired, abandoned, "turn registry maintenance");
                }
            }
        });
    }

    /// Drop finished turns past `ttl`. Shared by `evict_expired` (periodic) and
    /// `purge` (on insert).
    fn drop_expired(map: &mut HashMap<String, Arc<ActiveTurn>>, ttl: Duration) {
        map.retain(|_, t| !matches!(t.terminal_age(), Some(age) if age >= ttl));
    }

    /// Evict finished turns past the result TTL, then enforce the size cap by
    /// dropping the oldest entries (terminal ones first, so a still-running turn
    /// isn't discarded while a finished one could go instead).
    fn purge(&self, map: &mut HashMap<String, Arc<ActiveTurn>>) {
        Self::drop_expired(map, self.result_ttl);
        while map.len() >= self.max {
            let victim = map
                .iter()
                .filter(|(_, t)| t.is_terminal())
                .min_by_key(|(_, t)| t.created_at)
                .map(|(k, _)| k.clone())
                .or_else(|| {
                    map.iter()
                        .min_by_key(|(_, t)| t.created_at)
                        .map(|(k, _)| k.clone())
                });
            match victim {
                Some(k) => {
                    if let Some(turn) = map.remove(&k) {
                        // A still-running eviction victim must be cancelled (as
                        // sweep_abandoned does): once it leaves the map, its
                        // token is unreachable from the cancel endpoint and the
                        // watchdog, so an un-fired token would orphan the
                        // generation with no way to ever stop it.
                        if !turn.is_terminal() {
                            turn.cancel.cancel();
                        }
                    }
                }
                None => break,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn registry() -> TurnRegistry {
        TurnRegistry::new(Duration::from_secs(900), 128, 1 << 20, 8 << 20)
    }

    #[test]
    fn get_or_create_is_new_once_then_attaches() {
        let reg = registry();
        let (a, new_a) = reg.get_or_create("k1");
        assert!(new_a, "first call creates the turn");
        let (b, new_b) = reg.get_or_create("k1");
        assert!(!new_b, "second call attaches to the existing turn");
        assert!(Arc::ptr_eq(&a, &b), "same ActiveTurn instance is returned");
    }

    #[test]
    fn snapshot_returns_appended_events_and_done_flag() {
        let reg = registry();
        let (turn, _) = reg.get_or_create("k");
        turn.push(TurnEvent::Token("hi".into()));
        turn.push(TurnEvent::Token(" there".into()));

        let (events, done) = turn.snapshot_from(0);
        assert_eq!(events.len(), 2);
        assert!(!done, "not terminal until a Done/Error");

        turn.push(TurnEvent::Done {
            reason: "stop".into(),
        });
        let (events, done) = turn.snapshot_from(0);
        assert_eq!(events.len(), 3);
        assert!(done, "Done marks the turn terminal");
    }

    #[test]
    fn snapshot_from_cursor_returns_only_the_tail() {
        let reg = registry();
        let (turn, _) = reg.get_or_create("k");
        turn.push(TurnEvent::Token("a".into()));
        turn.push(TurnEvent::Token("b".into()));
        turn.push(TurnEvent::Token("c".into()));

        let (tail, _) = turn.snapshot_from(2);
        assert_eq!(
            tail.len(),
            1,
            "resume from index 2 yields only the 3rd event"
        );

        // A cursor past the end clamps to empty rather than panicking.
        let (empty, _) = turn.snapshot_from(99);
        assert!(empty.is_empty());
    }

    #[test]
    fn attach_after_completion_replays_full_log() {
        // The core "finished while backgrounded" case: a responder that attaches
        // only after the turn is terminal still sees every event.
        let reg = registry();
        let (turn, _) = reg.get_or_create("k");
        turn.push(TurnEvent::Token("answer".into()));
        turn.push(TurnEvent::Done {
            reason: "stop".into(),
        });

        let (replayed, done) = turn.snapshot_from(0);
        assert_eq!(replayed.len(), 2);
        assert!(done);
    }

    #[test]
    fn finish_marks_terminal_without_an_event() {
        let reg = registry();
        let (turn, _) = reg.get_or_create("k");
        turn.push(TurnEvent::Token("partial".into()));
        turn.finish();
        let (events, done) = turn.snapshot_from(0);
        assert_eq!(events.len(), 1, "finish appends no event");
        assert!(done, "but the turn reads as terminal so responders stop");
    }

    #[test]
    fn per_turn_byte_cap_emits_terminal_error_and_cancels_work() {
        let reg = TurnRegistry::new(Duration::from_secs(900), 8, 64, 1024);
        let (turn, _) = reg.get_or_create("large");
        assert!(!turn.push(TurnEvent::Token("x".repeat(128))));
        let (events, done) = turn.snapshot_from(0);
        assert!(done);
        assert!(turn.cancel.is_cancelled());
        assert!(matches!(events.as_slice(), [TurnEvent::Error(message)]
            if message.contains("buffer exceeded")));
    }

    #[test]
    fn registry_byte_cap_is_shared_and_released_on_eviction() {
        // Each 40-byte token costs 72 bytes with event overhead.
        let reg = TurnRegistry::new(Duration::from_secs(900), 8, 1024, 100);
        let (first, _) = reg.get_or_create("first");
        assert!(first.push(TurnEvent::Token("a".repeat(40))));
        let (second, _) = reg.get_or_create("second");
        assert!(!second.push(TurnEvent::Token("b".repeat(40))));

        reg.remove("first");
        drop(first);
        let (third, _) = reg.get_or_create("third");
        assert!(third.push(TurnEvent::Token("c".repeat(40))));
    }

    #[test]
    fn over_cap_evicts_terminal_entries_first() {
        let reg = TurnRegistry::new(Duration::from_secs(900), 2, 1 << 20, 8 << 20);
        // Two terminal turns, then a fresh create should evict a terminal one,
        // not exceed the cap.
        let (t1, _) = reg.get_or_create("k1");
        t1.finish();
        let (t2, _) = reg.get_or_create("k2");
        t2.finish();
        let (_t3, new3) = reg.get_or_create("k3");
        assert!(new3);
        // At most `max` entries remain.
        assert!(reg.map.lock().unwrap().len() <= 2);
        // k3 (the newest) survived.
        assert!(reg.get("k3").is_some());
    }

    #[test]
    fn over_cap_eviction_cancels_a_running_victim() {
        // With only running turns to choose from, purge evicts the oldest one —
        // and must fire its token, or the evicted generation would keep running
        // with no way left to cancel it (its token is gone from the map).
        let reg = TurnRegistry::new(Duration::from_secs(900), 2, 1 << 20, 8 << 20);
        let (running, _) = reg.get_or_create("old-running");
        let (finished, _) = reg.get_or_create("old-finished");
        finished.finish();

        let (_new, is_new) = reg.get_or_create("new");
        assert!(is_new);
        // The terminal turn goes first and needs no cancel; nothing running was
        // touched yet.
        assert!(reg.get("old-finished").is_none());
        assert!(!finished.cancel.is_cancelled(), "terminal eviction: no-op");
        assert!(!running.cancel.is_cancelled());

        // Next insert must evict the running turn — and cancel it.
        let (_newer, is_new) = reg.get_or_create("newer");
        assert!(is_new);
        assert!(reg.get("old-running").is_none(), "running turn evicted");
        assert!(
            running.cancel.is_cancelled(),
            "evicted running turn must be cancelled, not orphaned"
        );
    }

    #[test]
    fn sweep_cancels_detached_running_turns_only() {
        let reg = registry();

        // Running, detached since creation (never attached) → abandoned.
        let (abandoned, _) = reg.get_or_create("gone");

        // Running but currently attached → kept.
        let (attached, _) = reg.get_or_create("live");
        attached.attach();

        // Terminal (finished) → kept regardless of listeners.
        let (finished, _) = reg.get_or_create("done");
        finished.push(TurnEvent::Done {
            reason: "stop".into(),
        });

        // grace 0: any detached running turn is abandoned immediately.
        let swept = reg.sweep_abandoned(Duration::ZERO);
        assert_eq!(swept, 1, "only the detached running turn is swept");
        assert!(abandoned.cancel.is_cancelled(), "swept turn is cancelled");
        assert!(reg.get("gone").is_none(), "swept turn is removed");
        assert!(reg.get("live").is_some(), "attached turn is kept");
        assert!(reg.get("done").is_some(), "terminal turn is kept");
        assert!(!attached.cancel.is_cancelled());
        assert!(!finished.cancel.is_cancelled());
    }

    #[test]
    fn evict_expired_drops_only_finished_turns_past_ttl() {
        // ttl 0 → any terminal turn is immediately expired; running turns stay.
        let reg = TurnRegistry::new(Duration::ZERO, 128, 1 << 20, 8 << 20);
        let (running, _) = reg.get_or_create("run");
        let (finished, _) = reg.get_or_create("fin");
        finished.push(TurnEvent::Done {
            reason: "stop".into(),
        });

        let dropped = reg.evict_expired();
        assert_eq!(dropped, 1, "only the finished turn is evicted");
        assert!(reg.get("fin").is_none());
        assert!(
            reg.get("run").is_some(),
            "a running turn is never TTL-evicted"
        );
        let _ = running;
    }

    #[test]
    fn detach_rearms_the_abandoned_clock() {
        let reg = registry();
        let (turn, _) = reg.get_or_create("k");
        turn.attach();
        assert!(
            !turn.is_abandoned(Duration::ZERO),
            "attached turn is never abandoned"
        );
        turn.detach();
        assert!(
            turn.is_abandoned(Duration::ZERO),
            "once the last listener leaves, the turn can be reclaimed"
        );
    }

    #[tokio::test]
    async fn changed_wakes_on_push() {
        let reg = registry();
        let (turn, _) = reg.get_or_create("k");
        let mut rx = turn.subscribe();
        let writer = turn.clone();
        tokio::spawn(async move {
            writer.push(TurnEvent::Token("x".into()));
        });
        // Should resolve once the push bumps the watch value.
        rx.changed().await.expect("watch sender stays alive");
        let (events, _) = turn.snapshot_from(0);
        assert_eq!(events.len(), 1);
    }
}
