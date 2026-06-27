//! Warm container pool for the code-execution tool.
//!
//! Running untrusted, model-authored code safely means a fresh, hardened, network
//! -filtered container per execution. Creating one cold per call costs hundreds of
//! ms; to hide that, we keep `code_exec_pool_size` pre-warmed containers idle and
//! borrow one per run (`<runtime> exec`, ~tens of ms). Each container serves
//! **exactly one** execution: after the run it is destroyed and a replacement is
//! spun up in the background, so no filesystem state, leftover processes, or egress
//! state ever leak between runs.
//!
//! The pool is long-lived shared state (it lives in `AppState`, not in the
//! per-request `ToolRegistry`) and is cheaply cloneable (`Arc` inside).
//!
//! Testability: all container operations go through the [`ContainerBackend`] trait,
//! so the pool's borrow/recycle/concurrency logic is unit-tested with an in-memory
//! mock — no real containers, no Docker/Podman in CI. The trait uses boxed futures
//! (rather than `async fn`) so it stays object-safe for `Arc<dyn ContainerBackend>`.

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

use crate::config::Config;

/// A boxed, `Send` future — the object-safe return shape for [`ContainerBackend`].
type PoolFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// How a lane's containers attach to the network — the only difference between the
/// two code-exec tools. `None` (no internet at all) backs the offline `code_exec`
/// tool; `Named`/`RuntimeDefault` back the internet-capable `code_exec_online`.
#[derive(Debug, Clone)]
pub enum NetworkMode {
    /// `--network none`: no networking, not even loopback to other containers.
    None,
    /// `--network <name>`: a deployment-configured, egress-firewalled network.
    Named(String),
    /// No `--network` flag: the runtime default network (unfiltered — dev/test).
    RuntimeDefault,
}

impl NetworkMode {
    /// Resolve the online lane's mode from config: the firewalled network when one
    /// is set, otherwise the runtime default (documented as dev/test only).
    fn online(cfg: &Config) -> Self {
        match &cfg.code_exec_network {
            Some(n) => NetworkMode::Named(n.clone()),
            None => NetworkMode::RuntimeDefault,
        }
    }
}

/// Captured result of one code execution.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExecOutput {
    pub stdout: String,
    pub stderr: String,
    /// Process exit code, when the process exited normally.
    pub exit_code: Option<i32>,
    /// The run hit the wall-clock timeout and was killed.
    pub timed_out: bool,
    /// Output exceeded `code_exec_output_chars` and was truncated.
    pub truncated: bool,
}

impl ExecOutput {
    fn timed_out(secs: u64) -> Self {
        ExecOutput {
            stdout: String::new(),
            stderr: format!("execution timed out after {secs}s"),
            exit_code: None,
            timed_out: true,
            truncated: false,
        }
    }
}

/// A handle to one pooled container. Cheap (just the container name); the runtime
/// owns the actual process.
#[derive(Debug, Clone)]
pub struct Container {
    pub name: String,
}

/// The container operations the pool needs, behind a trait so tests can substitute
/// an in-memory mock. Never panics; every fallible step returns `Err(String)` which
/// the pool surfaces as a non-fatal tool message.
pub trait ContainerBackend: Send + Sync {
    /// Start a fresh, hardened, idle container and return a handle to it.
    fn spawn_container<'a>(&'a self, cfg: &'a Config) -> PoolFuture<'a, Result<Container, String>>;
    /// Force-remove a container (and everything running in it). Idempotent.
    fn destroy<'a>(&'a self, c: &'a Container) -> PoolFuture<'a, Result<(), String>>;
    /// Run `code` in language `language` inside an existing container, returning its
    /// captured (and capped) output.
    fn exec<'a>(
        &'a self,
        c: &'a Container,
        language: &'a str,
        code: &'a str,
        cfg: &'a Config,
    ) -> PoolFuture<'a, Result<ExecOutput, String>>;
}

struct PoolInner {
    cfg: Arc<Config>,
    backend: Arc<dyn ContainerBackend>,
    /// Pre-warmed, idle containers waiting to be borrowed. Never grows past
    /// `cfg.code_exec_pool_size`.
    ready: Mutex<VecDeque<Container>>,
    /// Bounds concurrent executions (== pool size). A borrower past the limit
    /// awaits a free permit rather than spawning unboundedly.
    slots: Semaphore,
}

impl PoolInner {
    fn take_ready(&self) -> Option<Container> {
        self.ready.lock().expect("ready lock").pop_front()
    }

    fn pool_size(&self) -> usize {
        self.cfg.code_exec_pool_size
    }
}

/// A warm pool of one-shot execution containers. Clone is cheap (shared `Arc`).
#[derive(Clone)]
pub struct CodeExecPool(Arc<PoolInner>);

impl CodeExecPool {
    /// Build one production lane (shelling out to `cfg.code_exec_runtime` with the
    /// given `network` mode) and kick off background warm-up. Returns `Err` only on
    /// a clearly-unusable config; warm-up failures are non-fatal (logged) — the pool
    /// still serves via cold fallback.
    pub fn new(cfg: Arc<Config>, network: NetworkMode) -> Result<Self, String> {
        if cfg.code_exec_runtime.trim().is_empty() {
            return Err("CODE_EXEC_RUNTIME is empty".into());
        }
        let backend = Arc::new(PodmanBackend::new(cfg.code_exec_runtime.clone(), network));
        let pool = Self::with_backend(cfg, backend);
        pool.warm();
        Ok(pool)
    }

    /// Construct a pool over an arbitrary backend without warming it. The seam used
    /// by tests (with a mock backend) and by [`new`](Self::new).
    pub fn with_backend(cfg: Arc<Config>, backend: Arc<dyn ContainerBackend>) -> Self {
        let n = cfg.code_exec_pool_size.max(1);
        CodeExecPool(Arc::new(PoolInner {
            backend,
            ready: Mutex::new(VecDeque::with_capacity(n)),
            slots: Semaphore::new(n),
            cfg,
        }))
    }

    /// Spawn `pool_size` containers in the background and park them as ready. Each
    /// is independent; failures just leave the pool below target (cold fallback
    /// covers the gap).
    pub fn warm(&self) {
        for _ in 0..self.0.pool_size() {
            let inner = self.0.clone();
            tokio::spawn(async move {
                match inner.backend.spawn_container(&inner.cfg).await {
                    Ok(c) => park_ready(&inner, c),
                    Err(e) => tracing::warn!(error = %e, "code-exec warm-up: container failed"),
                }
            });
        }
    }

    /// Run `code` once. Borrows a ready container (or cold-spawns one if the pool is
    /// still warming / drained), executes with a wall-clock timeout, and recycles
    /// the container afterwards regardless of outcome. `cancel` aborts an in-flight
    /// run; the container is still recycled, so no orphaned work survives.
    pub async fn execute(
        &self,
        language: &str,
        code: &str,
        cancel: &CancellationToken,
    ) -> Result<ExecOutput, String> {
        let inner = &self.0;
        // Backpressure: at most `pool_size` executions run at once.
        let _permit = inner
            .slots
            .acquire()
            .await
            .map_err(|_| "code-exec pool is shut down".to_string())?;

        let container = match inner.take_ready() {
            Some(c) => c,
            None => inner.backend.spawn_container(&inner.cfg).await?,
        };

        let timeout = Duration::from_secs(inner.cfg.code_exec_timeout_s.max(1));
        let result = tokio::select! {
            r = inner.backend.exec(&container, language, code, &inner.cfg) => r,
            _ = tokio::time::sleep(timeout) => Ok(ExecOutput::timed_out(inner.cfg.code_exec_timeout_s)),
            _ = cancel.cancelled() => Err("cancelled".to_string()),
        };

        // Always recycle: a completed, timed-out, or cancelled container is
        // destroyed (force-killing any orphaned process) and replaced off the hot
        // path. Each container thus serves exactly one execution.
        self.spawn_recycle(container);
        result
    }

    /// Destroy a used container and, if the pool is below target, spin up a
    /// replacement — all in the background so the caller never waits on it.
    fn spawn_recycle(&self, used: Container) {
        let inner = self.0.clone();
        tokio::spawn(async move {
            let _ = inner.backend.destroy(&used).await;
            let below_target = inner.ready.lock().expect("ready lock").len() < inner.pool_size();
            if !below_target {
                return;
            }
            match inner.backend.spawn_container(&inner.cfg).await {
                Ok(fresh) => park_ready(&inner, fresh),
                Err(e) => tracing::warn!(error = %e, "code-exec recycle: replacement failed"),
            }
        });
    }
}

/// The two code-exec lanes, each its own warm pool: `offline` runs with no network
/// (backs the `code_exec` tool, always available) and `online` runs with internet
/// via the egress-filtered network (backs `code_exec_online`, offered when web
/// access is on). Clone is cheap (both pools are `Arc`-backed).
#[derive(Clone)]
pub struct CodeExecPools {
    pub offline: CodeExecPool,
    pub online: CodeExecPool,
}

impl CodeExecPools {
    /// Build both lanes and start warming them. The offline lane uses
    /// `--network none`; the online lane uses the configured egress-filtered
    /// network (or the runtime default when none is configured — dev/test only).
    pub fn new(cfg: Arc<Config>) -> Result<Self, String> {
        let offline = CodeExecPool::new(cfg.clone(), NetworkMode::None)?;
        let online = CodeExecPool::new(cfg.clone(), NetworkMode::online(&cfg))?;
        Ok(CodeExecPools { offline, online })
    }
}

/// Park a freshly-started container as ready, unless the ready queue is already at
/// target (which can happen under churn) — in which case destroy the surplus so the
/// pool never exceeds `pool_size` idle containers.
fn park_ready(inner: &Arc<PoolInner>, c: Container) {
    let surplus = {
        let mut q = inner.ready.lock().expect("ready lock");
        if q.len() < inner.pool_size() {
            q.push_back(c);
            None
        } else {
            Some(c)
        }
    };
    if let Some(extra) = surplus {
        let inner = inner.clone();
        tokio::spawn(async move {
            let _ = inner.backend.destroy(&extra).await;
        });
    }
}

/// Production backend: shells out to `podman`/`docker`.
pub struct PodmanBackend {
    runtime: String,
    network: NetworkMode,
}

impl PodmanBackend {
    pub fn new(runtime: String, network: NetworkMode) -> Self {
        PodmanBackend { runtime, network }
    }
}

impl ContainerBackend for PodmanBackend {
    fn spawn_container<'a>(&'a self, cfg: &'a Config) -> PoolFuture<'a, Result<Container, String>> {
        Box::pin(async move {
            let name = format!("phantasm-codeexec-{}", uuid::Uuid::new_v4().simple());
            let mut cmd = Command::new(&self.runtime);
            cmd.arg("run")
                .arg("-d")
                .arg("--name")
                .arg(&name)
                .arg("--memory")
                .arg(&cfg.code_exec_memory)
                .arg("--cpus")
                .arg(&cfg.code_exec_cpus)
                .arg("--pids-limit")
                .arg(cfg.code_exec_pids_limit.to_string())
                .arg("--read-only")
                .arg("--tmpfs")
                .arg("/tmp:rw,size=64m")
                .arg("--user")
                .arg(&cfg.code_exec_run_user)
                .arg("--cap-drop")
                .arg("ALL")
                .arg("--security-opt")
                .arg("no-new-privileges");
            // Network depends on this lane's mode. The offline lane gets no network
            // at all; the online lane attaches to the egress-firewalled network
            // (internet yes, internal/metadata no — a deployment concern) or, if
            // none is configured, the runtime default (dev/test only).
            match &self.network {
                NetworkMode::None => {
                    cmd.arg("--network").arg("none");
                }
                NetworkMode::Named(net) => {
                    cmd.arg("--network").arg(net);
                }
                NetworkMode::RuntimeDefault => {}
            }
            cmd.arg(&cfg.code_exec_image);

            let out = cmd
                .output()
                .await
                .map_err(|e| format!("cannot start {}: {e}", self.runtime))?;
            if !out.status.success() {
                return Err(format!(
                    "container start failed: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                ));
            }
            Ok(Container { name })
        })
    }

    fn destroy<'a>(&'a self, c: &'a Container) -> PoolFuture<'a, Result<(), String>> {
        Box::pin(async move {
            // `-f` force-removes a running container (and its processes). Best
            // effort: a missing container ("no such container") is fine.
            let _ = Command::new(&self.runtime)
                .arg("rm")
                .arg("-f")
                .arg(&c.name)
                .output()
                .await;
            Ok(())
        })
    }

    fn exec<'a>(
        &'a self,
        c: &'a Container,
        language: &'a str,
        code: &'a str,
        cfg: &'a Config,
    ) -> PoolFuture<'a, Result<ExecOutput, String>> {
        Box::pin(async move {
            let mut child = Command::new(&self.runtime)
                .arg("exec")
                .arg("-i")
                .arg(&c.name)
                .arg("/usr/local/bin/run-code")
                .arg(language)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                // If the future is dropped (timeout/cancel), kill the `exec` client;
                // the container itself is reaped separately by recycle.
                .kill_on_drop(true)
                .spawn()
                .map_err(|e| format!("cannot run {} exec: {e}", self.runtime))?;

            // Feed the source on stdin from a task so output reads start immediately
            // — a script that floods stdout can't deadlock the stdin write.
            if let Some(mut stdin) = child.stdin.take() {
                let data = code.as_bytes().to_vec();
                tokio::spawn(async move {
                    let _ = stdin.write_all(&data).await;
                    let _ = stdin.shutdown().await;
                });
            }

            let stdout = child.stdout.take().expect("piped stdout");
            let stderr = child.stderr.take().expect("piped stderr");
            let cap = cfg.code_exec_output_chars;
            let (so, se, status) = tokio::join!(
                read_capped(stdout, cap),
                read_capped(stderr, cap),
                child.wait(),
            );
            let status = status.map_err(|e| format!("exec wait failed: {e}"))?;
            Ok(ExecOutput {
                stdout: so.0,
                stderr: se.0,
                exit_code: status.code(),
                timed_out: false,
                truncated: so.1 || se.1,
            })
        })
    }
}

/// Read a stream, keeping at most `cap` bytes but always draining to EOF so the
/// child can finish (and our memory stays bounded). Returns the kept text and
/// whether anything was dropped.
async fn read_capped<R: AsyncRead + Unpin>(mut r: R, cap: usize) -> (String, bool) {
    let mut kept: Vec<u8> = Vec::new();
    let mut scratch = [0u8; 8192];
    let mut truncated = false;
    loop {
        match r.read(&mut scratch).await {
            Ok(0) => break,
            Ok(n) => {
                if kept.len() < cap {
                    let take = (cap - kept.len()).min(n);
                    kept.extend_from_slice(&scratch[..take]);
                    if take < n {
                        truncated = true;
                    }
                } else {
                    truncated = true;
                }
            }
            Err(_) => break,
        }
    }
    (String::from_utf8_lossy(&kept).into_owned(), truncated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// In-memory backend: counts spawn/destroy, returns canned exec output, and can
    /// gate `exec` on a barrier to test concurrency.
    #[derive(Default)]
    struct MockBackend {
        spawned: AtomicUsize,
        destroyed: AtomicUsize,
        execed: AtomicUsize,
        fail_spawn: bool,
        hold: Option<Arc<tokio::sync::Notify>>,
    }

    impl ContainerBackend for MockBackend {
        fn spawn_container<'a>(
            &'a self,
            _cfg: &'a Config,
        ) -> PoolFuture<'a, Result<Container, String>> {
            Box::pin(async move {
                if self.fail_spawn {
                    return Err("spawn failed".into());
                }
                let n = self.spawned.fetch_add(1, Ordering::SeqCst);
                Ok(Container {
                    name: format!("mock-{n}"),
                })
            })
        }

        fn destroy<'a>(&'a self, _c: &'a Container) -> PoolFuture<'a, Result<(), String>> {
            Box::pin(async move {
                self.destroyed.fetch_add(1, Ordering::SeqCst);
                Ok(())
            })
        }

        fn exec<'a>(
            &'a self,
            _c: &'a Container,
            language: &'a str,
            _code: &'a str,
            _cfg: &'a Config,
        ) -> PoolFuture<'a, Result<ExecOutput, String>> {
            Box::pin(async move {
                self.execed.fetch_add(1, Ordering::SeqCst);
                if let Some(hold) = &self.hold {
                    hold.notified().await;
                }
                Ok(ExecOutput {
                    stdout: format!("ran {language}"),
                    ..Default::default()
                })
            })
        }
    }

    fn cfg(pool_size: usize) -> Arc<Config> {
        let mut c = crate::config::tests_support::minimal();
        c.code_exec_enabled = true;
        c.code_exec_pool_size = pool_size;
        Arc::new(c)
    }

    /// Drain the background recycle/warm tasks so their effects are observable.
    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test]
    async fn cold_falls_back_when_empty_then_runs() {
        let backend = Arc::new(MockBackend::default());
        let pool = CodeExecPool::with_backend(cfg(2), backend.clone());
        // with_backend does not warm, so the ready queue starts empty.
        let out = pool
            .execute("python", "print(1)", &CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(out.stdout, "ran python");
        assert!(backend.spawned.load(Ordering::SeqCst) >= 1);
    }

    #[tokio::test]
    async fn each_run_recycles_its_container() {
        let backend = Arc::new(MockBackend::default());
        let pool = CodeExecPool::with_backend(cfg(2), backend.clone());
        pool.execute("bash", "echo hi", &CancellationToken::new())
            .await
            .unwrap();
        settle().await;
        // The borrowed container was destroyed and a replacement spawned.
        assert_eq!(backend.destroyed.load(Ordering::SeqCst), 1);
        assert!(
            backend.spawned.load(Ordering::SeqCst) >= 2,
            "one cold container + one replacement"
        );
    }

    #[tokio::test]
    async fn spawn_failure_surfaces_as_error_not_panic() {
        let backend = Arc::new(MockBackend {
            fail_spawn: true,
            ..Default::default()
        });
        let pool = CodeExecPool::with_backend(cfg(1), backend);
        let err = pool
            .execute("python", "x", &CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(err, "spawn failed");
    }

    #[tokio::test]
    async fn cancellation_returns_cancelled_and_recycles() {
        let hold = Arc::new(tokio::sync::Notify::new());
        let backend = Arc::new(MockBackend {
            hold: Some(hold.clone()),
            ..Default::default()
        });
        let pool = CodeExecPool::with_backend(cfg(1), backend.clone());
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let handle = {
            let pool = pool.clone();
            tokio::spawn(async move { pool.execute("python", "x", &token).await })
        };
        // Let exec start (and block on the barrier), then cancel.
        settle().await;
        cancel.cancel();
        let res = handle.await.unwrap();
        assert_eq!(res.unwrap_err(), "cancelled");
        settle().await;
        assert_eq!(
            backend.destroyed.load(Ordering::SeqCst),
            1,
            "cancelled run still recycles its container"
        );
    }

    #[tokio::test]
    async fn concurrency_is_capped_at_pool_size() {
        let hold = Arc::new(tokio::sync::Notify::new());
        let backend = Arc::new(MockBackend {
            hold: Some(hold.clone()),
            ..Default::default()
        });
        let pool = CodeExecPool::with_backend(cfg(1), backend.clone());
        assert_eq!(pool.0.slots.available_permits(), 1);

        // First execution acquires the only permit and blocks on the barrier.
        let p1 = pool.clone();
        let h1 =
            tokio::spawn(async move { p1.execute("python", "a", &CancellationToken::new()).await });
        settle().await;
        assert_eq!(backend.execed.load(Ordering::SeqCst), 1);
        assert_eq!(
            pool.0.slots.available_permits(),
            0,
            "the permit is held for the duration of the run"
        );

        // Release the run; the permit returns to the pool.
        hold.notify_waiters();
        let _ = h1.await.unwrap();
        settle().await;
        assert_eq!(pool.0.slots.available_permits(), 1);
    }
}
