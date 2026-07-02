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
use url::Url;

/// Join `path` onto `base`, **appending** to any path prefix the base carries.
///
/// `Url::join("/x")` resolves an absolute path against the origin, silently
/// erasing a configured base path — `https://ghe.corp/api/v3` + `/search/code`
/// came out as `https://ghe.corp/search/code`. Every tool builds its endpoint
/// URLs through this instead. A trailing slash on the base is tolerated;
/// `path` is treated as segments to append whether or not it has a leading
/// slash.
pub fn join_base(base: &Url, path: &str) -> Url {
    let mut url = base.clone();
    let prefix = base.path().trim_end_matches('/');
    let suffix = path.trim_start_matches('/');
    url.set_path(&format!("{prefix}/{suffix}"));
    url
}

/// Default total per-request deadline for JSON API calls (connect, TLS,
/// headers, and the whole body).
pub const JSON_TIMEOUT: Duration = Duration::from_secs(30);

/// Default raw-body cap for JSON API responses. Generous — these are search
/// results, forecasts, scoreboards, quotes — while bounding what one response
/// can make us buffer.
pub const JSON_BODY_CAP: usize = 2 * 1024 * 1024;

/// A required, non-blank string argument, trimmed — or a uniform
/// "missing required" error naming the field. Shared by the tools that take
/// operation-dependent optional args (github, market_data).
pub fn required<'a>(value: &'a Option<String>, name: &str) -> Result<&'a str, String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("missing required `{name}`"))
}

/// Marker preceding a stored image id in a `/v1/files/<id>` reference.
const FILES_MARKER: &str = "/v1/files/";

/// The leading run of file-id characters (the base64url alphabet) in `s`.
fn id_run(s: &str) -> &str {
    let end = s
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
        .unwrap_or(s.len());
    &s[..end]
}

/// Extract the `<id>` from a `…/v1/files/<id>…` reference (a full signed URL,
/// a site-relative path, or a markdown link target). `None` when the marker is
/// absent or no id follows it — a plain external URL is not an id.
pub fn file_ref_id(target: &str) -> Option<&str> {
    let start = target.find(FILES_MARKER)? + FILES_MARKER.len();
    let id = id_run(&target[start..]);
    (!id.is_empty()).then_some(id)
}

/// Like [`file_ref_id`], but a marker-less reference is treated as a bare id
/// (the image-edit tool accepts `image_ref: "<id>"`). May return an empty
/// slice for garbage input; the blob store rejects malformed ids downstream.
pub fn file_ref_id_or_bare(reference: &str) -> &str {
    match reference.find(FILES_MARKER) {
        Some(i) => id_run(&reference[i + FILES_MARKER.len()..]),
        None => id_run(reference),
    }
}

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

    #[test]
    fn required_trims_and_rejects_blank() {
        assert_eq!(required(&Some(" x ".into()), "f").unwrap(), "x");
        assert!(required(&Some("   ".into()), "f").is_err());
        assert_eq!(
            required(&None, "symbol").unwrap_err(),
            "missing required `symbol`"
        );
    }

    #[test]
    fn file_ref_id_parses_url_and_relative_targets() {
        assert_eq!(
            file_ref_id("https://host/v1/files/abc123/content?exp=1&sig=z"),
            Some("abc123")
        );
        assert_eq!(file_ref_id("/v1/files/DEF-_4/content"), Some("DEF-_4"));
        // No marker, or nothing after it: not an id.
        assert_eq!(file_ref_id("https://example.com/image.png"), None);
        assert_eq!(file_ref_id("/v1/files//content"), None);
    }

    #[test]
    fn file_ref_id_or_bare_accepts_bare_ids() {
        assert_eq!(file_ref_id_or_bare("abc123"), "abc123");
        assert_eq!(
            file_ref_id_or_bare("https://host/v1/files/abc123/content"),
            "abc123"
        );
    }

    #[test]
    fn join_base_appends_to_a_path_prefix() {
        // The GHE-style case Url::join used to break: the /api/v3 prefix must
        // survive, with or without a trailing slash on the base.
        let base: Url = "https://ghe.corp/api/v3".parse().unwrap();
        assert_eq!(
            join_base(&base, "/search/code").as_str(),
            "https://ghe.corp/api/v3/search/code"
        );
        let slash: Url = "https://ghe.corp/api/v3/".parse().unwrap();
        assert_eq!(
            join_base(&slash, "/search/code").as_str(),
            "https://ghe.corp/api/v3/search/code"
        );
    }

    #[test]
    fn join_base_works_from_a_bare_origin() {
        let base: Url = "https://api.github.com".parse().unwrap();
        assert_eq!(
            join_base(&base, "/search/code").as_str(),
            "https://api.github.com/search/code"
        );
        assert_eq!(
            join_base(&base, "history/abc123").as_str(),
            "https://api.github.com/history/abc123"
        );
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
