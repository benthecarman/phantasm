//! Phantasm orchestrator entrypoint.

use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use phantasm_orchestrator::config::{Config, LogFormat};
use phantasm_orchestrator::state::AppState;
use phantasm_orchestrator::{build_state, detect_upstream, probe_capabilities, routes};
use tracing::info;
use tracing_subscriber::{prelude::*, EnvFilter};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cfg = Config::from_env().context("loading configuration from environment")?;
    init_tracing(cfg.log_format);

    let cfg = Arc::new(cfg);

    // A throwaway client just for the startup probes; AppState builds its own.
    let probe_http = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(2))
        .build()
        .context("building HTTP client")?;
    let upstream = detect_upstream(&cfg, &probe_http).await;
    let capabilities = Arc::new(probe_capabilities(&cfg, &probe_http, &upstream).await);
    info!(
        upstream = ?upstream.kind,
        models = capabilities.models.len(),
        vision_models = capabilities.vision_models.len(),
        tool_models = capabilities.tool_models.len(),
        web_search = capabilities.tools.web_search,
        image_generation = capabilities.tools.image_generation,
        "capabilities resolved"
    );

    let state: AppState = build_state(cfg.clone(), capabilities, upstream.kind);
    let app = routes::router(state);

    let listener = tokio::net::TcpListener::bind(cfg.bind_addr)
        .await
        .with_context(|| format!("binding {}", cfg.bind_addr))?;
    info!(addr = %cfg.bind_addr, "phantasm orchestrator listening");
    notify_systemd_ready();

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("server error")?;
    Ok(())
}

fn init_tracing(format: LogFormat) {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,phantasm_orchestrator=info"));
    let registry = tracing_subscriber::registry().with(filter);
    match format {
        LogFormat::Json => registry
            .with(tracing_subscriber::fmt::layer().json())
            .init(),
        LogFormat::Text => registry.with(tracing_subscriber::fmt::layer()).init(),
    }
}

/// Tell systemd we've bound and are ready to serve. No-op unless launched by a
/// `Type=notify` unit (i.e. `$NOTIFY_SOCKET` is set), so dev/Docker runs are
/// unaffected. Lets `systemctl start` block until we're actually listening and
/// orders dependent units after us. Graceful SIGTERM drain is already handled by
/// `shutdown_signal`, which pairs with the unit's `TimeoutStopSec`.
#[cfg(unix)]
fn notify_systemd_ready() {
    if let Err(e) = sd_notify::notify(true, &[sd_notify::NotifyState::Ready]) {
        tracing::debug!(error = %e, "sd_notify READY skipped (not under systemd?)");
    }
}

#[cfg(not(unix))]
fn notify_systemd_ready() {}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c().await.ok();
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sig) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sig.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    info!("shutdown signal received");
}
