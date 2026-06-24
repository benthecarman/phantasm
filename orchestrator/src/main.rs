//! Phantasm orchestrator entrypoint.

use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use phantasm_orchestrator::config::{Config, LogFormat};
use phantasm_orchestrator::ollama::OllamaClient;
use phantasm_orchestrator::state::AppState;
use phantasm_orchestrator::{build_state, probe_capabilities, routes};
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
        .build()
        .context("building HTTP client")?;
    let probe_ollama = OllamaClient::new(probe_http.clone(), cfg.ollama_base.clone());

    let capabilities = Arc::new(probe_capabilities(&cfg, &probe_ollama, &probe_http).await);
    info!(
        models = capabilities.models.len(),
        web_search = capabilities.tools.web_search,
        image_generation = capabilities.tools.image_generation,
        "capabilities resolved"
    );

    let state: AppState = build_state(cfg.clone(), capabilities);
    let app = routes::router(state);

    let listener = tokio::net::TcpListener::bind(cfg.bind_addr)
        .await
        .with_context(|| format!("binding {}", cfg.bind_addr))?;
    info!(addr = %cfg.bind_addr, "phantasm orchestrator listening");

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
