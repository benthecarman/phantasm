//! Phantasm orchestrator entrypoint.

use std::sync::Arc;

use anyhow::Context;
use phantasm_orchestrator::config::{Config, LogFormat};
use phantasm_orchestrator::state::AppState;
use phantasm_orchestrator::{
    build_http_client, build_state_with_upstreams, detect_upstreams, probe_capabilities, routes,
};
use tracing::info;
use tracing_subscriber::{prelude::*, EnvFilter};

const USAGE: &str = "usage: phantasm-orchestrator            start the server\n       \
                     phantasm-orchestrator pair [URL] print a pairing QR (docs/qr-pairing.md)";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Subcommand dispatch before any config/server work: `pair` must run with
    // partial env (docs/qr-pairing.md), so it can't go through Config::from_env.
    // The bare invocation stays the server.
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("pair") => {
            let url = args.next();
            // A silently dropped extra argument would mint a QR the operator
            // didn't ask for (e.g. a mis-quoted `pair https://h token`).
            if let Some(extra) = args.next() {
                anyhow::bail!("unexpected extra argument `{extra}`\n{USAGE}");
            }
            return phantasm_orchestrator::pairing::run(url);
        }
        Some("help" | "--help" | "-h") => {
            println!("{USAGE}");
            return Ok(());
        }
        Some("--version" | "-V") => {
            println!("phantasm-orchestrator {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Some(other) => anyhow::bail!("unknown argument `{other}`\n{USAGE}"),
        None => {}
    }

    let cfg = Config::from_env().context("loading configuration from environment")?;
    init_tracing(cfg.log_format);
    // Logged here, not in `Config::from_env`: that runs before `init_tracing`,
    // where a warning would go to the no-op subscriber and never be seen.
    if cfg.auth_disabled() {
        tracing::warn!(
            "PHANTASM_AUTH_TOKEN is unset or empty: bearer auth is DISABLED, all \
             requests will be accepted unauthenticated"
        );
    }

    let cfg = Arc::new(cfg);

    let http = build_http_client().context("building HTTP client")?;
    let upstreams = detect_upstreams(&cfg, &http).await;
    for entry in upstreams.entries() {
        info!(
            upstream = %entry.name,
            kind = ?entry.kind,
            base = %entry.base,
            models = entry.models().len(),
            pinned = entry.pinned(),
            max_concurrency = entry.max_concurrency,
            "upstream configured"
        );
    }
    // Detection just probed every upstream's models; reuse those lists.
    let capabilities = Arc::new(probe_capabilities(&cfg, &http, &upstreams, true).await);
    let vision_models = capabilities
        .models
        .iter()
        .filter(|model| {
            model
                .capabilities
                .as_ref()
                .is_some_and(|capabilities| capabilities.vision)
        })
        .count();
    let tool_models = capabilities
        .models
        .iter()
        .filter(|model| {
            model
                .capabilities
                .as_ref()
                .is_some_and(|capabilities| capabilities.tools)
        })
        .count();
    let completion_models = capabilities
        .models
        .iter()
        .filter(|model| {
            model
                .capabilities
                .as_ref()
                .is_some_and(|capabilities| capabilities.completion)
        })
        .count();
    info!(
        upstreams = upstreams.entries().len(),
        models = capabilities.models.len(),
        completion_models,
        vision_models,
        tool_models,
        web_search = capabilities.has_tool_selector("web_search"),
        utilities = capabilities.has_tool_selector("utilities"),
        image_generation = capabilities.has_tool_selector("image_generation"),
        "capabilities resolved"
    );

    let state: AppState = build_state_with_upstreams(cfg.clone(), capabilities, http, upstreams);
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
