//! Bearer-token authentication middleware (FR-O7).
//!
//! When a token is configured, every gated route requires it: a missing or
//! non-matching `Authorization: Bearer <token>` header is rejected with 401
//! before any handler runs. When no token is configured (`auth_token` is
//! `None`), auth is disabled and every request passes through unauthenticated.
//!
//! The observability routes (`/metrics`, `/dashboard/data`) are gated by their
//! own token so the credential handed to a Prometheus scraper (or stored in a
//! dashboard browser) never grants chat access — and vice versa. When no
//! metrics token is configured they fall back to the main token.

use axum::extract::State;
use axum::http::{header::AUTHORIZATION, Request};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::error::AppError;
use crate::state::AppState;

/// Gate for the main API routes, against `PHANTASM_AUTH_TOKEN`.
pub async fn require_bearer(
    State(state): State<AppState>,
    req: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let expected = state.cfg.auth_token.clone();
    gate(expected, state, req, next).await
}

/// Gate for `/metrics` + `/dashboard/data`, against `PHANTASM_METRICS_TOKEN`.
/// Unset => the main token gates them too (zero-config compatibility); set =>
/// it is the ONLY accepted token here, and it opens nothing else.
pub async fn require_metrics_bearer(
    State(state): State<AppState>,
    req: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let expected = state
        .cfg
        .metrics_token
        .clone()
        .or_else(|| state.cfg.auth_token.clone());
    gate(expected, state, req, next).await
}

async fn gate(
    expected: Option<String>,
    state: AppState,
    req: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let Some(expected) = expected else {
        // Auth disabled (no token configured): accept everything.
        return next.run(req).await;
    };
    match extract_token(&req) {
        Some(token) if constant_time_eq(token, &expected) => next.run(req).await,
        _ => {
            // For an internet-exposed self-hosted server, a spike here is the
            // closest thing to a security signal — count it for the dashboard.
            state.metrics.http_unauthorized.inc();
            AppError::Unauthorized.into_response()
        }
    }
}

fn extract_token<B>(req: &Request<B>) -> Option<&str> {
    req.headers()
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|t| !t.is_empty())
}

/// Length-aware constant-time comparison to avoid leaking the token via timing.
fn constant_time_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constant_time_eq_matches() {
        assert!(constant_time_eq("secret", "secret"));
        assert!(!constant_time_eq("secret", "secrft"));
        assert!(!constant_time_eq("secret", "secret-longer"));
        assert!(!constant_time_eq("", "x"));
    }
}
