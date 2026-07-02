//! Durable metrics tier: an embedded SQLite event store behind the in-memory
//! registry (`metrics`). One row per turn / tool call / usage report, so the
//! dashboard gets real percentiles and arbitrary time ranges that survive
//! restarts. Volumes are tiny on a self-hosted box, so per-event rows are
//! cheap.
//!
//! Writes go through a dedicated OS thread that owns the connection (WAL
//! mode), fed by an unbounded channel — recorder call sites never block and
//! never fail. Reads happen on separate read-only connections opened by the
//! dashboard route inside `spawn_blocking`. If the database can't be opened
//! at boot the orchestrator degrades to memory-only metrics; storage is never
//! fatal, matching the tool-failure philosophy (NFR-O6).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OpenFlags};
use serde::Serialize;
use tokio::sync::{mpsc, oneshot};

use crate::metrics::TurnOutcome;

/// One durable metric event, stamped with the wall-clock time at insert.
#[derive(Debug)]
pub enum MetricEvent {
    Turn {
        model: String,
        mode: Option<String>,
        outcome: TurnOutcome,
        duration_ms: u64,
        ttft_ms: Option<u64>,
        used_tools: bool,
    },
    ToolCall {
        tool: String,
        model: String,
        ok: bool,
        duration_ms: u64,
    },
    Usage {
        model: String,
        prompt_tokens: Option<u64>,
        completion_tokens: Option<u64>,
        tokens_per_sec: Option<f64>,
        load_ms: Option<u64>,
    },
}

enum StoreMsg {
    Event(MetricEvent),
    /// Commit everything received so far, then ack. Used by tests and by a
    /// graceful shutdown to bound data loss.
    Flush(oneshot::Sender<()>),
}

/// Cheap-clone handle to the writer thread plus the path read connections use.
#[derive(Clone)]
pub struct StoreHandle {
    tx: mpsc::UnboundedSender<StoreMsg>,
    path: PathBuf,
}

impl StoreHandle {
    /// Fire-and-forget; a closed writer (shutdown) drops the event silently.
    pub fn send(&self, ev: MetricEvent) {
        let _ = self.tx.send(StoreMsg::Event(ev));
    }

    /// Wait until all previously sent events are committed.
    pub async fn flush(&self) {
        let (ack, done) = oneshot::channel();
        if self.tx.send(StoreMsg::Flush(ack)).is_ok() {
            let _ = done.await;
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS turns (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,
  model TEXT,
  mode TEXT,
  outcome TEXT NOT NULL,
  duration_ms INTEGER NOT NULL,
  ttft_ms INTEGER,
  used_tools INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_turns_ts ON turns(ts);
CREATE TABLE IF NOT EXISTS tool_calls (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,
  tool TEXT NOT NULL,
  model TEXT,
  ok INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tool_calls_ts ON tool_calls(ts);
CREATE TABLE IF NOT EXISTS usage (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,
  model TEXT,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  tokens_per_sec REAL,
  load_ms INTEGER
);
CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage(ts);
";

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn init_connection(path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.execute_batch(SCHEMA)?;
    conn.pragma_update(None, "user_version", 1)?;
    Ok(conn)
}

/// Open the store and spawn its writer thread. Returns `Err` (for a warn +
/// memory-only fallback) if the database can't be opened or initialized.
pub fn spawn(path: PathBuf, retention_days: u32) -> Result<StoreHandle, String> {
    let conn = init_connection(&path).map_err(|e| e.to_string())?;
    let (tx, rx) = mpsc::unbounded_channel();
    std::thread::Builder::new()
        .name("metrics-store".into())
        .spawn(move || writer_loop(conn, rx, retention_days))
        .map_err(|e| e.to_string())?;
    Ok(StoreHandle { tx, path })
}

fn writer_loop(
    mut conn: Connection,
    mut rx: mpsc::UnboundedReceiver<StoreMsg>,
    retention_days: u32,
) {
    let mut last_prune = Instant::now();
    prune(&conn, retention_days);
    while let Some(first) = rx.blocking_recv() {
        let mut events = Vec::new();
        let mut acks = Vec::new();
        let push =
            |msg: StoreMsg, events: &mut Vec<MetricEvent>, acks: &mut Vec<oneshot::Sender<()>>| {
                match msg {
                    StoreMsg::Event(ev) => events.push(ev),
                    StoreMsg::Flush(ack) => acks.push(ack),
                }
            };
        push(first, &mut events, &mut acks);
        while events.len() < 256 {
            match rx.try_recv() {
                Ok(msg) => push(msg, &mut events, &mut acks),
                Err(_) => break,
            }
        }
        if !events.is_empty() {
            if let Err(e) = insert_batch(&mut conn, &events) {
                tracing::warn!(error = %e, dropped = events.len(), "metrics store insert failed");
            }
        }
        for ack in acks {
            let _ = ack.send(());
        }
        if last_prune.elapsed() > Duration::from_secs(3600) {
            prune(&conn, retention_days);
            last_prune = Instant::now();
        }
    }
    // Channel closed: all senders (the Metrics registry) are gone; the
    // connection drop checkpoints WAL as part of close.
}

fn insert_batch(conn: &mut Connection, events: &[MetricEvent]) -> rusqlite::Result<()> {
    let ts = now_secs();
    let tx = conn.transaction()?;
    for ev in events {
        match ev {
            MetricEvent::Turn {
                model,
                mode,
                outcome,
                duration_ms,
                ttft_ms,
                used_tools,
            } => {
                tx.execute(
                    "INSERT INTO turns (ts, model, mode, outcome, duration_ms, ttft_ms, used_tools)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        ts,
                        model,
                        mode,
                        outcome.as_str(),
                        *duration_ms as i64,
                        ttft_ms.map(|v| v as i64),
                        *used_tools as i64
                    ],
                )?;
            }
            MetricEvent::ToolCall {
                tool,
                model,
                ok,
                duration_ms,
            } => {
                tx.execute(
                    "INSERT INTO tool_calls (ts, tool, model, ok, duration_ms) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![ts, tool, model, *ok as i64, *duration_ms as i64],
                )?;
            }
            MetricEvent::Usage {
                model,
                prompt_tokens,
                completion_tokens,
                tokens_per_sec,
                load_ms,
            } => {
                tx.execute(
                    "INSERT INTO usage (ts, model, prompt_tokens, completion_tokens, tokens_per_sec, load_ms)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        ts,
                        model,
                        prompt_tokens.map(|v| v as i64),
                        completion_tokens.map(|v| v as i64),
                        tokens_per_sec,
                        load_ms.map(|v| v as i64)
                    ],
                )?;
            }
        }
    }
    tx.commit()
}

fn prune(conn: &Connection, retention_days: u32) {
    let cutoff = now_secs() - i64::from(retention_days) * 86_400;
    for table in ["turns", "tool_calls", "usage"] {
        if let Err(e) = conn.execute(
            &format!("DELETE FROM {table} WHERE ts < ?1"),
            params![cutoff],
        ) {
            tracing::warn!(table, error = %e, "metrics store prune failed");
        }
    }
}

/// Read-only connection for dashboard queries (WAL permits concurrent reads).
pub fn open_read(path: &Path) -> rusqlite::Result<Connection> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
}

// ---- Dashboard queries -----------------------------------------------------

#[derive(Debug, Default, Serialize)]
pub struct OutcomeCounts {
    pub completed: u64,
    pub errored: u64,
    pub cancelled: u64,
    pub with_tools: u64,
    pub plain: u64,
}

#[derive(Debug, Default, Serialize)]
pub struct LatencySummary {
    pub count: u64,
    pub p50_ms: Option<u64>,
    pub p95_ms: Option<u64>,
    pub ttft_p50_ms: Option<u64>,
    pub ttft_p95_ms: Option<u64>,
}

#[derive(Debug, Default, Serialize)]
pub struct TokenTotals {
    pub prompt: u64,
    pub completion: u64,
    pub avg_tokens_per_sec: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct ToolRow {
    pub tool: String,
    pub calls: u64,
    pub errors: u64,
    pub p95_ms: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct ModelRow {
    pub model: String,
    pub turns: u64,
    pub errored: u64,
    pub p95_ms: Option<u64>,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub avg_tokens_per_sec: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct SeriesPoint {
    pub t: i64,
    pub turns: u64,
    pub errors: u64,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub tool_calls: u64,
}

#[derive(Debug, Default, Serialize)]
pub struct DashboardHistory {
    pub outcomes: OutcomeCounts,
    pub latency: LatencySummary,
    pub tokens: TokenTotals,
    pub tools: Vec<ToolRow>,
    pub models: Vec<ModelRow>,
    pub series: Vec<SeriesPoint>,
}

fn percentile(sorted: &[u64], p: f64) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted.get(idx).copied()
}

/// Everything the dashboard needs for one range. `model` filters the
/// range-scoped sections; the per-model summary is always aggregate-wide.
pub fn dashboard_history(
    conn: &Connection,
    since_ts: i64,
    bucket_secs: i64,
    model: Option<&str>,
) -> rusqlite::Result<DashboardHistory> {
    let model_clause = if model.is_some() {
        " AND model = ?2"
    } else {
        ""
    };
    let bind = |q: &str| q.replace("{M}", model_clause);
    // rusqlite params can't be conditionally sized easily; run two variants.
    macro_rules! query {
        ($sql:expr, $f:expr) => {{
            let sql = bind($sql);
            let mut stmt = conn.prepare(&sql)?;
            match model {
                Some(m) => stmt
                    .query_map(params![since_ts, m], $f)?
                    .collect::<Result<Vec<_>, _>>()?,
                None => stmt
                    .query_map(params![since_ts], $f)?
                    .collect::<Result<Vec<_>, _>>()?,
            }
        }};
    }

    let mut out = DashboardHistory::default();

    // Outcome + tool-usage counts.
    let rows: Vec<(String, i64, i64)> =
        query!(
        "SELECT outcome, COUNT(*), SUM(used_tools) FROM turns WHERE ts >= ?1{M} GROUP BY outcome",
        |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, Option<i64>>(2)?.unwrap_or(0)))
    );
    for (outcome, count, with_tools) in rows {
        let count = count as u64;
        out.outcomes.with_tools += with_tools as u64;
        out.outcomes.plain += count - with_tools as u64;
        match outcome.as_str() {
            "completed" => out.outcomes.completed = count,
            "errored" => out.outcomes.errored = count,
            "cancelled" => out.outcomes.cancelled = count,
            _ => {}
        }
    }

    // Latency percentiles from raw rows (volumes are small by design).
    let durations: Vec<(i64, Option<i64>)> = query!(
        "SELECT duration_ms, ttft_ms FROM turns WHERE ts >= ?1{M}",
        |r| Ok((r.get(0)?, r.get(1)?))
    );
    let mut dur: Vec<u64> = durations.iter().map(|(d, _)| *d as u64).collect();
    let mut ttft: Vec<u64> = durations
        .iter()
        .filter_map(|(_, t)| t.map(|t| t as u64))
        .collect();
    dur.sort_unstable();
    ttft.sort_unstable();
    out.latency = LatencySummary {
        count: dur.len() as u64,
        p50_ms: percentile(&dur, 0.5),
        p95_ms: percentile(&dur, 0.95),
        ttft_p50_ms: percentile(&ttft, 0.5),
        ttft_p95_ms: percentile(&ttft, 0.95),
    };

    // Token totals + mean throughput.
    let totals: Vec<(i64, i64, Option<f64>)> = query!(
        "SELECT COALESCE(SUM(prompt_tokens),0), COALESCE(SUM(completion_tokens),0), AVG(tokens_per_sec)
         FROM usage WHERE ts >= ?1{M}",
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))
    );
    if let Some((p, c, tps)) = totals.into_iter().next() {
        out.tokens = TokenTotals {
            prompt: p as u64,
            completion: c as u64,
            avg_tokens_per_sec: tps,
        };
    }

    // Per-tool table (range + model scoped): p95 from raw durations.
    let tool_rows: Vec<(String, i64, i64)> = query!(
        "SELECT tool, COUNT(*), SUM(ok = 0) FROM tool_calls WHERE ts >= ?1{M} GROUP BY tool ORDER BY COUNT(*) DESC",
        |r| Ok((r.get(0)?, r.get(1)?, r.get::<_, Option<i64>>(2)?.unwrap_or(0)))
    );
    for (tool, calls, errors) in tool_rows {
        let sql = bind("SELECT duration_ms FROM tool_calls WHERE ts >= ?1{M} AND tool = ?3 ORDER BY duration_ms");
        // ?3 only exists in the model variant; renumber for the bare one.
        let raw: Vec<i64> = match model {
            Some(m) => {
                let mut stmt = conn.prepare(&sql)?;
                let rows = stmt
                    .query_map(params![since_ts, m, tool], |r| r.get::<_, i64>(0))?
                    .collect::<Result<Vec<_>, _>>()?;
                rows
            }
            None => {
                let mut stmt = conn.prepare(
                    "SELECT duration_ms FROM tool_calls WHERE ts >= ?1 AND tool = ?2 ORDER BY duration_ms",
                )?;
                let rows = stmt
                    .query_map(params![since_ts, tool], |r| r.get::<_, i64>(0))?
                    .collect::<Result<Vec<_>, _>>()?;
                rows
            }
        };
        let mut durations: Vec<u64> = raw.into_iter().map(|d| d as u64).collect();
        durations.sort_unstable();
        out.tools.push(ToolRow {
            tool,
            calls: calls as u64,
            errors: errors as u64,
            p95_ms: percentile(&durations, 0.95),
        });
    }

    // Per-model summary: always aggregate-wide (ignores the model filter) so
    // the breakdown stays visible while filtered.
    let mut stmt = conn.prepare(
        "SELECT COALESCE(model,''), COUNT(*), SUM(outcome = 'errored') FROM turns WHERE ts >= ?1 GROUP BY model",
    )?;
    let model_turns: Vec<(String, i64, i64)> = stmt
        .query_map(params![since_ts], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get::<_, Option<i64>>(2)?.unwrap_or(0),
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for (m, turns, errored) in model_turns {
        let mut stmt =
            conn.prepare("SELECT duration_ms FROM turns WHERE ts >= ?1 AND COALESCE(model,'') = ?2 ORDER BY duration_ms")?;
        let mut durs: Vec<u64> = stmt
            .query_map(params![since_ts, m], |r| r.get::<_, i64>(0))?
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .map(|d| d as u64)
            .collect();
        durs.sort_unstable();
        let mut stmt = conn.prepare(
            "SELECT COALESCE(SUM(prompt_tokens),0), COALESCE(SUM(completion_tokens),0), AVG(tokens_per_sec)
             FROM usage WHERE ts >= ?1 AND COALESCE(model,'') = ?2",
        )?;
        let (p, c, tps): (i64, i64, Option<f64>) = stmt.query_row(params![since_ts, m], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?;
        out.models.push(ModelRow {
            model: m,
            turns: turns as u64,
            errored: errored as u64,
            p95_ms: percentile(&durs, 0.95),
            prompt_tokens: p as u64,
            completion_tokens: c as u64,
            avg_tokens_per_sec: tps,
        });
    }
    out.models.sort_by(|a, b| b.turns.cmp(&a.turns));

    // Time series: merge the three tables' buckets.
    let mut buckets: BTreeMap<i64, SeriesPoint> = BTreeMap::new();
    let point = |t: i64| SeriesPoint {
        t,
        turns: 0,
        errors: 0,
        prompt_tokens: 0,
        completion_tokens: 0,
        tool_calls: 0,
    };
    {
        let sql = bind(&format!(
            "SELECT (ts / {b}) * {b}, COUNT(*), SUM(outcome = 'errored') FROM turns WHERE ts >= ?1{{M}} GROUP BY 1",
            b = bucket_secs
        ));
        let rows: Vec<(i64, i64, i64)> = {
            let mut stmt = conn.prepare(&sql)?;
            match model {
                Some(m) => stmt
                    .query_map(params![since_ts, m], |r| {
                        Ok((
                            r.get(0)?,
                            r.get(1)?,
                            r.get::<_, Option<i64>>(2)?.unwrap_or(0),
                        ))
                    })?
                    .collect::<Result<Vec<_>, _>>()?,
                None => stmt
                    .query_map(params![since_ts], |r| {
                        Ok((
                            r.get(0)?,
                            r.get(1)?,
                            r.get::<_, Option<i64>>(2)?.unwrap_or(0),
                        ))
                    })?
                    .collect::<Result<Vec<_>, _>>()?,
            }
        };
        for (t, turns, errors) in rows {
            let e = buckets.entry(t).or_insert_with(|| point(t));
            e.turns = turns as u64;
            e.errors = errors as u64;
        }
    }
    {
        let sql = bind(&format!(
            "SELECT (ts / {b}) * {b}, COALESCE(SUM(prompt_tokens),0), COALESCE(SUM(completion_tokens),0)
             FROM usage WHERE ts >= ?1{{M}} GROUP BY 1",
            b = bucket_secs
        ));
        let rows: Vec<(i64, i64, i64)> = {
            let mut stmt = conn.prepare(&sql)?;
            match model {
                Some(m) => stmt
                    .query_map(params![since_ts, m], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                    })?
                    .collect::<Result<Vec<_>, _>>()?,
                None => stmt
                    .query_map(params![since_ts], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                    .collect::<Result<Vec<_>, _>>()?,
            }
        };
        for (t, p, c) in rows {
            let e = buckets.entry(t).or_insert_with(|| point(t));
            e.prompt_tokens = p as u64;
            e.completion_tokens = c as u64;
        }
    }
    {
        let sql = bind(&format!(
            "SELECT (ts / {b}) * {b}, COUNT(*) FROM tool_calls WHERE ts >= ?1{{M}} GROUP BY 1",
            b = bucket_secs
        ));
        let rows: Vec<(i64, i64)> = {
            let mut stmt = conn.prepare(&sql)?;
            match model {
                Some(m) => stmt
                    .query_map(params![since_ts, m], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<Result<Vec<_>, _>>()?,
                None => stmt
                    .query_map(params![since_ts], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<Result<Vec<_>, _>>()?,
            }
        };
        for (t, calls) in rows {
            let e = buckets.entry(t).or_insert_with(|| point(t));
            e.tool_calls = calls as u64;
        }
    }
    out.series = buckets.into_values().collect();

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seeded() -> (tempfile::TempDir, StoreHandle) {
        let dir = tempfile::tempdir().unwrap();
        let handle = spawn(dir.path().join("m.sqlite"), 30).unwrap();
        (dir, handle)
    }

    #[tokio::test]
    async fn round_trip_and_aggregate() {
        let (_dir, store) = seeded();
        store.send(MetricEvent::Turn {
            model: "llama3".into(),
            mode: None,
            outcome: TurnOutcome::Completed,
            duration_ms: 1200,
            ttft_ms: Some(300),
            used_tools: true,
        });
        store.send(MetricEvent::Turn {
            model: "llama3".into(),
            mode: Some("research".into()),
            outcome: TurnOutcome::Errored,
            duration_ms: 400,
            ttft_ms: None,
            used_tools: false,
        });
        store.send(MetricEvent::Turn {
            model: "qwen".into(),
            mode: None,
            outcome: TurnOutcome::Completed,
            duration_ms: 900,
            ttft_ms: Some(100),
            used_tools: false,
        });
        store.send(MetricEvent::ToolCall {
            tool: "web_search".into(),
            model: "llama3".into(),
            ok: false,
            duration_ms: 250,
        });
        store.send(MetricEvent::Usage {
            model: "llama3".into(),
            prompt_tokens: Some(100),
            completion_tokens: Some(40),
            tokens_per_sec: Some(20.0),
            load_ms: None,
        });
        store.flush().await;

        let conn = open_read(store.path()).unwrap();
        let all = dashboard_history(&conn, 0, 60, None).unwrap();
        assert_eq!(all.outcomes.completed, 2);
        assert_eq!(all.outcomes.errored, 1);
        assert_eq!(all.outcomes.with_tools, 1);
        assert_eq!(all.outcomes.plain, 2);
        assert_eq!(all.latency.count, 3);
        assert_eq!(all.tokens.prompt, 100);
        assert_eq!(all.tools.len(), 1);
        assert_eq!(all.tools[0].errors, 1);
        assert_eq!(all.models.len(), 2);
        assert_eq!(all.models[0].model, "llama3"); // sorted by turn count
        assert_eq!(all.models[0].prompt_tokens, 100);
        assert_eq!(all.series.len(), 1); // everything lands in one minute bucket
        assert_eq!(all.series[0].turns, 3);
        assert_eq!(all.series[0].tool_calls, 1);

        // Model filter scopes range sections but not the per-model summary.
        let filtered = dashboard_history(&conn, 0, 60, Some("qwen")).unwrap();
        assert_eq!(filtered.outcomes.completed, 1);
        assert_eq!(filtered.outcomes.errored, 0);
        assert_eq!(filtered.tools.len(), 0);
        assert_eq!(filtered.models.len(), 2);

        // Out-of-range cutoff excludes everything.
        let none = dashboard_history(&conn, now_secs() + 60, 60, None).unwrap();
        assert_eq!(none.latency.count, 0);
        assert!(none.series.is_empty());
    }

    #[tokio::test]
    async fn retention_prunes_old_rows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("m.sqlite");
        {
            // Seed a row far in the past directly.
            let conn = init_connection(&path).unwrap();
            conn.execute(
                "INSERT INTO turns (ts, model, outcome, duration_ms, used_tools) VALUES (?1, 'old', 'completed', 1, 0)",
                params![now_secs() - 90 * 86_400],
            )
            .unwrap();
        }
        // Spawning the writer prunes on startup.
        let store = spawn(path.clone(), 30).unwrap();
        store.flush().await;
        let conn = open_read(&path).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM turns", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn percentile_math() {
        assert_eq!(percentile(&[], 0.5), None);
        assert_eq!(percentile(&[10], 0.95), Some(10));
        let v: Vec<u64> = (1..=100).collect();
        assert_eq!(percentile(&v, 0.5), Some(51)); // rounded nearest-rank
        assert_eq!(percentile(&v, 0.95), Some(95));
    }
}
