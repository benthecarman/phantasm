//! The `pair` subcommand (FR-O10, SPEC §2.2d, docs/qr-pairing.md).
//!
//! Prints a `phantasm://pair` URI and an ANSI-rendered QR of it, then exits —
//! one line in the terminal to pair a device after install. Deliberately does
//! NOT go through `Config::from_env`: pairing needs only the token and a URL
//! the phone can reach, and it must work right after install before the
//! upstream vars are wired. Emission is interactive-only by design — the URI
//! embeds the bearer token, so it must never appear in service logs.

use anyhow::{anyhow, Context};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use qrcode::render::unicode;
use qrcode::QrCode;
use url::Url;

use crate::config::env_nonempty;

/// Build the v1 pairing URI. `name` defaults to the URL's host so the app has
/// a label without deriving one. Values are RFC 3986 percent-encoded (never
/// `+`-for-space: iOS `URLComponents` decodes per RFC 3986 only).
pub fn build_pairing_uri(url: &Url, token: Option<&str>) -> String {
    let mut uri = format!("phantasm://pair?v=1&url={}", encode_component(url.as_str()));
    if let Some(token) = token {
        uri.push_str("&token=");
        uri.push_str(&encode_component(token));
    }
    if let Some(host) = url.host_str() {
        uri.push_str("&name=");
        uri.push_str(&encode_component(host));
    }
    uri
}

/// Resolve the URL to embed: explicit argument > `PAIR_URL` > `PUBLIC_BASE_URL`.
/// No LAN-IP guessing — a QR encoding a host the phone can't reach is worse
/// than no QR (docs/qr-pairing.md).
pub fn resolve_pair_url(
    arg: Option<&str>,
    pair_url: Option<&str>,
    public_base_url: Option<&str>,
) -> anyhow::Result<Url> {
    let (raw, source) = arg
        .map(|v| (v, "argument"))
        .or_else(|| pair_url.map(|v| (v, "PAIR_URL")))
        .or_else(|| public_base_url.map(|v| (v, "PUBLIC_BASE_URL")))
        .ok_or_else(|| {
            anyhow!(
                "no URL to embed: pass one (`phantasm-orchestrator pair https://host:8080`) \
                 or set PAIR_URL / PUBLIC_BASE_URL"
            )
        })?;
    let url = Url::parse(raw.trim()).with_context(|| format!("invalid URL from {source}"))?;
    match url.scheme() {
        "http" | "https" => Ok(url),
        other => Err(anyhow!("URL from {source} must be http(s), got `{other}`")),
    }
}

/// The RFC 3986 unreserved set, like JS `encodeURIComponent` (but stricter —
/// also `!*'()`), so tokens and hosts survive any query-string parser. The
/// iOS side (`PairingPayload.encodeComponent`) encodes the same set.
const COMPONENT: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~');

fn encode_component(s: &str) -> String {
    utf8_percent_encode(s, COMPONENT).to_string()
}

/// Entry point for `phantasm-orchestrator pair [URL]`.
pub fn run(url_arg: Option<String>) -> anyhow::Result<()> {
    let token = env_nonempty("PHANTASM_AUTH_TOKEN");
    let url = resolve_pair_url(
        url_arg.as_deref(),
        env_nonempty("PAIR_URL").as_deref(),
        env_nonempty("PUBLIC_BASE_URL").as_deref(),
    )?;
    if token.is_none() {
        // Mirrors the server's own auth-disabled warning: pairing without a
        // token is only correct when the deployment deliberately runs open.
        eprintln!(
            "warning: PHANTASM_AUTH_TOKEN is unset or empty — emitting a token-less \
             pairing URI (the backend must be running with auth disabled)"
        );
    }

    let uri = build_pairing_uri(&url, token.as_deref());
    let code = QrCode::new(uri.as_bytes()).context("encoding pairing URI as QR")?;
    // Inverted for the common dark-background terminal (light modules drawn as
    // foreground blocks); scanners read inverted codes, and the URI is printed
    // beneath as the fallback.
    let qr = code
        .render::<unicode::Dense1x2>()
        .dark_color(unicode::Dense1x2::Light)
        .light_color(unicode::Dense1x2::Dark)
        .build();

    println!("{qr}");
    println!("Scan with the iPhone camera to pair, or open on the device:");
    println!("{uri}");
    println!();
    println!("This code grants access to your backend — share it like the token itself.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    #[test]
    fn uri_includes_url_token_and_derived_name() {
        let uri = build_pairing_uri(&parse("https://host.example:8080"), Some("secret-token"));
        assert_eq!(
            uri,
            "phantasm://pair?v=1&url=https%3A%2F%2Fhost.example%3A8080%2F\
             &token=secret-token&name=host.example"
        );
    }

    #[test]
    fn token_absent_when_auth_disabled() {
        let uri = build_pairing_uri(&parse("http://10.0.0.5:11434"), None);
        assert!(!uri.contains("token="));
        assert!(uri.contains("name=10.0.0.5"));
    }

    #[test]
    fn exotic_token_is_percent_encoded_without_plus() {
        let uri = build_pairing_uri(&parse("https://h.example"), Some("a b&c=+/ü"));
        assert!(uri.contains("token=a%20b%26c%3D%2B%2F%C3%BC"));
        // `+` must only ever appear percent-encoded — iOS URLComponents does
        // not decode `+` as space.
        assert!(!uri.replace("%2B", "").contains('+'));
    }

    #[test]
    fn url_precedence_arg_then_pair_url_then_public_base() {
        let arg = resolve_pair_url(Some("https://a.example"), Some("https://b.example"), None);
        assert_eq!(arg.unwrap().host_str(), Some("a.example"));
        let env = resolve_pair_url(None, Some("https://b.example"), Some("https://c.example"));
        assert_eq!(env.unwrap().host_str(), Some("b.example"));
        let public = resolve_pair_url(None, None, Some("https://c.example"));
        assert_eq!(public.unwrap().host_str(), Some("c.example"));
    }

    #[test]
    fn missing_url_and_bad_schemes_are_rejected() {
        let err = resolve_pair_url(None, None, None).unwrap_err().to_string();
        assert!(err.contains("PAIR_URL"), "should name the vars: {err}");
        assert!(resolve_pair_url(Some("ftp://h"), None, None).is_err());
        assert!(resolve_pair_url(Some("not a url"), None, None).is_err());
    }
}
