//! Shared SSRF guard for outbound fetches whose target URL is influenced by
//! model or tool input (remote vision images, `web_fetch`, `web_search` page
//! reads). One implementation so the protections can't drift apart per tool.
//!
//! The guard, in order:
//!   1. parse the URL and require an `http`/`https` scheme;
//!   2. reject `localhost` (and `*.localhost`) by name;
//!   3. resolve the host and refuse if *any* resolved address is in a
//!      private/loopback/link-local/CGNAT/multicast/reserved range;
//!   4. **pin** the connection to the one validated address, so DNS rebinding
//!      can't swap in an internal target between the check and the fetch.
//!
//! Callers must also disable redirects on the client they build (a 3xx would
//! otherwise re-resolve to an unchecked host); [`pinned_client`] does this.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use url::Url;

/// A validated public URL together with the single IP its host resolved to.
/// Fetch it with a [`pinned_client`] so the host can't re-resolve elsewhere.
pub struct GuardedTarget {
    pub url: Url,
    pub host: String,
    pub addr: SocketAddr,
}

/// Validate `raw` as a fetchable public URL, then resolve and screen its host.
/// Returns the parsed URL plus the allowed socket address to pin to, or a
/// human-readable reason it was refused.
pub async fn guard_url(raw: &str) -> Result<GuardedTarget, String> {
    let url = Url::parse(raw).map_err(|e| format!("invalid URL: {e}"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err("only http and https URLs are allowed".into());
    }
    let host = url
        .host_str()
        .ok_or_else(|| "URL has no host".to_string())?
        .to_string();
    let lower = host.to_ascii_lowercase();
    if lower == "localhost" || lower.ends_with(".localhost") {
        return Err("localhost URLs are not allowed".into());
    }
    let port = url
        .port_or_known_default()
        .unwrap_or(if url.scheme() == "https" { 443 } else { 80 });
    let addr = resolve_allowed(&host, port).await?;
    Ok(GuardedTarget { url, host, addr })
}

/// Build a reqwest client that follows no redirects and is pinned to the
/// guarded target's resolved IP, so the host can't re-resolve to an internal
/// address. The returned client should be used only for `target.url`.
pub fn pinned_client(target: &GuardedTarget, timeout: Duration) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(timeout)
        .resolve(&target.host, target.addr)
        .build()
        .map_err(|e| format!("http client build failed: {e}"))
}

/// Resolve `host:port` and return the first address that isn't disallowed.
/// Errors if resolution fails or every address is private/loopback/etc.
pub async fn resolve_allowed(host: &str, port: u16) -> Result<SocketAddr, String> {
    let addrs = tokio::net::lookup_host((host, port))
        .await
        .map_err(|e| format!("could not resolve host: {e}"))?;
    for addr in addrs {
        if !ip_is_disallowed(addr.ip()) {
            return Ok(addr);
        }
    }
    Err("host resolves only to disallowed (private/loopback/link-local) addresses".into())
}

/// Whether an IP must not be fetched from — the SSRF blocklist. Conservative:
/// covers loopback, private, link-local, CGNAT-shared, multicast, unspecified,
/// documentation/reserved ranges, and the IPv6 forms that embed an IPv4
/// address (IPv4-mapped `::ffff:0:0/96`, NAT64 `64:ff9b::/96`, and the
/// deprecated IPv4-compatible `::/96`) — each re-checked as the embedded v4,
/// so `64:ff9b::7f00:1` can't smuggle a loopback target past the screen.
pub fn ip_is_disallowed(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4_disallowed(v4),
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return v4_disallowed(mapped);
            }
            let seg = v6.segments();
            // NAT64 well-known prefix 64:ff9b::/96: the last 32 bits are the
            // real IPv4 target, so screen that.
            if seg[..6] == [0x64, 0xff9b, 0, 0, 0, 0] {
                return v4_disallowed(embedded_v4(v6));
            }
            // Deprecated IPv4-compatible ::/96 (also covers `::` and `::1`,
            // whose embedded 0.0.0.0/0.0.0.1 fail the v4 screen).
            if seg[..6] == [0; 6] {
                return v4_disallowed(embedded_v4(v6));
            }
            let seg0 = seg[0];
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (seg0 & 0xfe00) == 0xfc00 // unique-local fc00::/7
                || (seg0 & 0xffc0) == 0xfe80 // link-local fe80::/10
        }
    }
}

/// The IPv4 address carried in the low 32 bits of an IPv6 address (used by the
/// mapped/NAT64/IPv4-compatible embedding formats).
fn embedded_v4(v6: std::net::Ipv6Addr) -> Ipv4Addr {
    let o = v6.octets();
    Ipv4Addr::new(o[12], o[13], o[14], o[15])
}

fn v4_disallowed(v4: Ipv4Addr) -> bool {
    let [a, b, ..] = v4.octets();
    v4.is_private()
        || v4.is_loopback()
        || v4.is_link_local()
        || v4.is_broadcast()
        || v4.is_documentation()
        || v4.is_unspecified()
        || v4.is_multicast()
        || a == 0 // 0.0.0.0/8 "this network"
        || (a == 100 && (64..128).contains(&b)) // CGNAT 100.64.0.0/10
        || a >= 240 // 240.0.0.0/4 reserved
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssrf_blocklist_covers_internal_ranges() {
        for bad in [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.1.1",
            "100.64.0.1",
            "0.0.0.0",
            "::1",
            "fc00::1",
            "fe80::1",
            "::ffff:127.0.0.1",
        ] {
            assert!(
                ip_is_disallowed(bad.parse().unwrap()),
                "{bad} should be blocked"
            );
        }
        for ok in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:2800:220:1::"] {
            assert!(
                !ip_is_disallowed(ok.parse().unwrap()),
                "{ok} should be allowed"
            );
        }
    }

    #[test]
    fn nat64_embedded_internal_v4_is_blocked() {
        // 64:ff9b::/96 carries the real IPv4 target in the low 32 bits; an
        // embedded internal address must be screened like the bare v4.
        for bad in [
            "64:ff9b::7f00:1",    // 127.0.0.1
            "64:ff9b::a00:1",     // 10.0.0.1
            "64:ff9b::c0a8:101",  // 192.168.1.1
            "64:ff9b::a9fe:a9fe", // 169.254.169.254 (metadata)
        ] {
            assert!(
                ip_is_disallowed(bad.parse().unwrap()),
                "{bad} should be blocked"
            );
        }
        // A NAT64 address embedding a public v4 stays reachable.
        assert!(!ip_is_disallowed("64:ff9b::808:808".parse().unwrap())); // 8.8.8.8
    }

    #[test]
    fn ipv4_compatible_embedded_internal_v4_is_blocked() {
        // Deprecated ::/96 embedding: same screen as the embedded v4.
        for bad in [
            "::7f00:1",   // 127.0.0.1
            "::a00:1",    // 10.0.0.1
            "::c0a8:101", // 192.168.1.1
        ] {
            assert!(
                ip_is_disallowed(bad.parse().unwrap()),
                "{bad} should be blocked"
            );
        }
    }

    #[tokio::test]
    async fn guard_url_rejects_scheme_and_localhost() {
        assert!(guard_url("file:///etc/passwd").await.is_err());
        assert!(guard_url("ftp://example.com/x").await.is_err());
        assert!(guard_url("http://localhost:8080").await.is_err());
        assert!(guard_url("http://api.internal.localhost/x").await.is_err());
        // A literal internal IP is refused at resolve time.
        assert!(guard_url("http://127.0.0.1:8080").await.is_err());
        assert!(guard_url("http://169.254.169.254/latest/meta-data")
            .await
            .is_err());
    }
}
