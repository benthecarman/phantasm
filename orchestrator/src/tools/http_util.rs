//! Shared HTTP plumbing for the tool modules.
//!
//! The tools' shared `reqwest::Client` sets connect/read timeouts but no
//! *total* request deadline, and `Response::json()` buffers the body without
//! limit — so a slow or hostile upstream could stall a turn or balloon memory.
//! Every JSON-API call site goes through the helpers here instead: a
//! per-request deadline covering connect through the last body byte, and a
//! streamed body read that refuses to buffer past a cap (the same pattern
//! `web_fetch`/`web_search` already use for page bodies).
//!
//! Errors are always rendered *without* the request URL: query strings can
//! carry secrets (e.g. the Alpha Vantage `apikey`), and these messages reach
//! both warn logs and the model-visible tool error.

use std::time::Duration;

use futures_util::StreamExt;
use serde::de::DeserializeOwned;

/// Default total per-request deadline for JSON API calls (connect, TLS,
/// headers, and the whole body).
pub const JSON_TIMEOUT: Duration = Duration::from_secs(30);

/// Default raw-body cap for JSON API responses. Generous — these are search
/// results, forecasts, scoreboards, quotes — while bounding what one response
/// can make us buffer.
pub const JSON_BODY_CAP: usize = 2 * 1024 * 1024;

/// Render a reqwest error without its URL. reqwest's default `Display`
/// includes the full request URL — query string and all — which can leak
/// query-borne secrets into logs and model-visible tool errors.
pub fn redact_reqwest_err(e: reqwest::Error) -> String {
    e.without_url().to_string()
}

/// Send `req` and parse its JSON body with the default deadline and body cap.
pub async fn get_json<T: DeserializeOwned>(req: reqwest::RequestBuilder) -> Result<T, String> {
    send_json(req, JSON_TIMEOUT, JSON_BODY_CAP).await
}

/// Send `req` with a total deadline and parse its JSON body, streamed in and
/// capped at `cap` bytes. A non-success status is an error (rendered without
/// the URL, like every other failure here).
pub async fn send_json<T: DeserializeOwned>(
    req: reqwest::RequestBuilder,
    timeout: Duration,
    cap: usize,
) -> Result<T, String> {
    let resp = req
        .timeout(timeout)
        .send()
        .await
        .map_err(redact_reqwest_err)?
        .error_for_status()
        .map_err(redact_reqwest_err)?;
    read_json(resp, cap).await
}

/// Stream a response body up to `cap` bytes and parse it as JSON. For call
/// sites that need their own status handling before the body read (the
/// caller should still have set a request deadline).
pub async fn read_json<T: DeserializeOwned>(
    resp: reqwest::Response,
    cap: usize,
) -> Result<T, String> {
    // Fast reject on an advertised oversized body before streaming any of it.
    if let Some(len) = resp.content_length() {
        if len as usize > cap {
            return Err(format!("response too large ({len} bytes > {cap} cap)"));
        }
    }
    // Stream-accumulate so a missing/lying Content-Length can't blow past the cap.
    let mut bytes = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(redact_reqwest_err)?;
        if bytes.len() + chunk.len() > cap {
            return Err(format!("response exceeds {cap} byte cap"));
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|e| format!("bad JSON response: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use wiremock::matchers::any;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    async fn server_with_body(body: Vec<u8>) -> MockServer {
        let server = MockServer::start().await;
        Mock::given(any())
            .respond_with(ResponseTemplate::new(200).set_body_bytes(body))
            .mount(&server)
            .await;
        server
    }

    #[tokio::test]
    async fn parses_json_under_the_cap() {
        let server = server_with_body(br#"{"ok": true}"#.to_vec()).await;
        let v: Value = send_json(reqwest::Client::new().get(server.uri()), JSON_TIMEOUT, 1024)
            .await
            .unwrap();
        assert_eq!(v["ok"], true);
    }

    #[tokio::test]
    async fn refuses_bodies_over_the_cap() {
        // 4 KiB of body against a 64-byte cap: the read must stop at the cap
        // rather than buffer the whole thing and fail only on parse.
        let server = server_with_body(vec![b'x'; 4096]).await;
        let err = send_json::<Value>(reqwest::Client::new().get(server.uri()), JSON_TIMEOUT, 64)
            .await
            .unwrap_err();
        assert!(err.contains("cap"), "{err}");
    }

    #[tokio::test]
    async fn non_success_status_is_an_error() {
        let server = MockServer::start().await;
        Mock::given(any())
            .respond_with(ResponseTemplate::new(503))
            .mount(&server)
            .await;
        let err = send_json::<Value>(reqwest::Client::new().get(server.uri()), JSON_TIMEOUT, 1024)
            .await
            .unwrap_err();
        assert!(err.contains("503"), "{err}");
    }

    #[tokio::test]
    async fn reqwest_errors_do_not_leak_query_secrets() {
        // Bind then drop a loopback listener so the port is closed: the send
        // fails with a real reqwest connect error that carries the request URL
        // (query string included). The redacted form must not echo the key.
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let url = format!("http://127.0.0.1:{port}/query?apikey=SUPERSECRETKEY");
        let err = reqwest::Client::new().get(&url).send().await.unwrap_err();
        let msg = redact_reqwest_err(err);
        assert!(!msg.contains("SUPERSECRETKEY"), "leaked key: {msg}");
        assert!(!msg.contains("apikey"), "leaked query string: {msg}");
    }
}
