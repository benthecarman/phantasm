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
}

struct TurnLog {
    events: Vec<TurnEvent>,
    /// Set once a terminal `Done`/`Error` is appended (or the producer's channel
    /// closes). Tells a responder to stop after draining.
    done: bool,
    /// When the turn reached a terminal state; drives result-TTL eviction.
    terminal_at: Option<Instant>,
}

impl ActiveTurn {
    fn new(cancel: CancellationToken) -> Self {
        let (len_tx, _) = watch::channel(0usize);
        ActiveTurn {
            inner: Mutex::new(TurnLog {
                events: Vec::new(),
                done: false,
                terminal_at: None,
            }),
            len_tx,
            cancel,
            created_at: Instant::now(),
        }
    }

    /// Append an event produced by the turn task, marking the turn terminal on a
    /// `Done`/`Error`, then wake attached responders.
    pub fn push(&self, event: TurnEvent) {
        let len = {
            let mut log = self.inner.lock().unwrap();
            if matches!(event, TurnEvent::Done { .. } | TurnEvent::Error(_)) {
                log.done = true;
                log.terminal_at.get_or_insert_with(Instant::now);
            }
            log.events.push(event);
            log.events.len()
        };
        // Bump the watch value so responders awaiting `changed()` wake.
        let _ = self.len_tx.send(len);
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

/// Store of buffered resumable turns, keyed by the client's `Idempotency-Key`.
#[derive(Clone)]
pub struct TurnRegistry {
    map: Arc<Mutex<HashMap<String, Arc<ActiveTurn>>>>,
    result_ttl: Duration,
    max: usize,
}

impl TurnRegistry {
    pub fn new(result_ttl: Duration, max: usize) -> Self {
        TurnRegistry {
            map: Arc::new(Mutex::new(HashMap::new())),
            result_ttl,
            max: max.max(1),
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
        let turn = Arc::new(ActiveTurn::new(CancellationToken::new()));
        map.insert(key.to_string(), turn.clone());
        (turn, true)
    }

    /// Look up a live turn without creating one (the cancel endpoint, phase 2).
    pub fn get(&self, key: &str) -> Option<Arc<ActiveTurn>> {
        self.map.lock().unwrap().get(key).cloned()
    }

    /// Drop a turn from the registry (e.g. after an explicit cancel).
    pub fn remove(&self, key: &str) -> Option<Arc<ActiveTurn>> {
        self.map.lock().unwrap().remove(key)
    }

    /// Evict finished turns past the result TTL, then enforce the size cap by
    /// dropping the oldest entries (terminal ones first, so a still-running turn
    /// isn't discarded while a finished one could go instead).
    fn purge(&self, map: &mut HashMap<String, Arc<ActiveTurn>>) {
        let ttl = self.result_ttl;
        map.retain(|_, t| !matches!(t.terminal_age(), Some(age) if age >= ttl));
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
                    map.remove(&k);
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
        TurnRegistry::new(Duration::from_secs(900), 128)
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
    fn over_cap_evicts_terminal_entries_first() {
        let reg = TurnRegistry::new(Duration::from_secs(900), 2);
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
