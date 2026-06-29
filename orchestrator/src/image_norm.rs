//! Request-image normalization — the boundary pass that turns every image a
//! client attaches into a validated, size-bounded, canonical `data:` URI before
//! the turn forwards it to Ollama's per-message `images` field.
//!
//! Why here and not in `OllamaMessage::from_openai`: the two-phase turn loop
//! re-issues the upstream call several times per turn, so conversion runs
//! repeatedly and must stay sync + cheap. Normalization is the opposite — async
//! (it may fetch a remote URL or read a store blob) — so it runs exactly once,
//! up front, and bakes its result into the message history the loop then reuses.
//!
//! What it fixes vs. the old `strip_data_uri`-only path, which shoved any
//! non-`data:` URL into Ollama's `images` field as if it were base64:
//!   * remote `http(s)` URLs are fetched (SSRF-guarded) and inlined;
//!   * `/v1/files/<id>` store refs are resolved to bytes — so the app can send a
//!     compact ref as *input*, not just receive one in a generated answer;
//!   * every image is sniffed and rejected if it isn't a real, supported image,
//!     instead of failing opaquely deep inside Ollama.
//!
//! Downscaling is deliberately *not* done here. The boundary keeps images at
//! full fidelity so the tools (OCR, image-edit) and the app operate on the
//! original resolution; the size reduction happens later, on a throwaway copy
//! bound only for Ollama's vision field — see [`downscale_messages_for_vision`].
//!
//! Errors are per-image and precise (which image, why), returned before the turn
//! starts so the client gets a clean HTTP status rather than a mangled stream.

use std::io::Cursor;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use futures_util::StreamExt;
use url::Url;

use crate::config::Config;
use crate::error::AppError;
use crate::images::{recognized_image_type, sniff_content_type, BlobStore};
use crate::openai::types::{extract_store_ids, ChatMessage, ContentPart, MessageContent};

const UNSUPPORTED: &str = "attached content is not a supported image (png/jpeg/gif/webp)";

/// Rewrite every attached `image_url` part across `messages` into a validated,
/// size-bounded `data:` URI. Mutates in place; returns the first per-image error
/// (so an invalid attachment fails the request loudly, not mid-stream).
///
/// Only `image_url` *parts* are touched — that's the multimodal input Ollama
/// sees. Images embedded as `data:` URIs in assistant *text* (the markdown the
/// image tools emit) are server-produced and ride the answer, not the vision
/// path, so they're left alone.
pub async fn normalize_request_images(
    messages: &mut [ChatMessage],
    cfg: &Config,
    store: Option<&BlobStore>,
) -> Result<(), AppError> {
    let mut index = 0usize;
    for msg in messages.iter_mut() {
        let Some(MessageContent::Parts(parts)) = msg.content.as_mut() else {
            continue;
        };
        for part in parts.iter_mut() {
            let ContentPart::ImageUrl { image_url } = part else {
                continue;
            };
            index += 1;
            if let Some(payload) = data_uri_payload(&image_url.url) {
                // Already inline at full fidelity — validate and keep it verbatim,
                // so a (possibly multi-MB) history image isn't re-encoded each turn.
                let bytes = STANDARD.decode(payload.trim()).map_err(|_| {
                    label(
                        index,
                        AppError::BadRequest("invalid base64 in image data URI".into()),
                    )
                })?;
                check_cap(&bytes, cfg).map_err(|e| label(index, e))?;
                if recognized_image_type(&bytes).is_none() {
                    return Err(label(index, AppError::BadRequest(UNSUPPORTED.into())));
                }
            } else {
                // Resolve a store ref / remote URL / bare base64, then inline it.
                // Downscaling is the vision projection's job
                // (`downscale_messages_for_vision`), kept off this path so the
                // stored history, the tools, and the app keep full resolution.
                let bytes = load_external(&image_url.url, cfg, store)
                    .await
                    .map_err(|e| label(index, e))?;
                let Some(mime) = recognized_image_type(&bytes) else {
                    return Err(label(index, AppError::BadRequest(UNSUPPORTED.into())));
                };
                image_url.url = format!("data:{mime};base64,{}", STANDARD.encode(&bytes));
            }
        }
    }
    Ok(())
}

/// Prefix an error with which image it concerns (images are 1-indexed in request
/// order across the whole history).
fn label(index: usize, err: AppError) -> AppError {
    let msg = match &err {
        AppError::BadRequest(m) | AppError::PayloadTooLarge(m) | AppError::Internal(m) => m.clone(),
        other => other.to_string(),
    };
    let text = format!("image #{index}: {msg}");
    match err {
        AppError::PayloadTooLarge(_) => AppError::PayloadTooLarge(text),
        AppError::Internal(_) => AppError::Internal(text),
        _ => AppError::BadRequest(text),
    }
}

/// Resolve a *non-inline* image reference to raw bytes: a `/v1/files/<id>` store
/// ref, a remote `http(s)` URL, or a bare base64 blob. Order matters: a signed
/// store ref is an absolute `http(s)` URL too, so it's matched first (and resolves
/// without a network round-trip, even with no public base). Inline `data:` URIs
/// are handled by the caller and never reach here.
async fn load_external(
    url: &str,
    cfg: &Config,
    store: Option<&BlobStore>,
) -> Result<Vec<u8>, AppError> {
    if let (Some(store), Some(id)) = (store, extract_store_ids(url).into_iter().next()) {
        let blob = store
            .get(&id)
            .await
            .ok_or_else(|| AppError::BadRequest("referenced image not found in store".into()))?;
        Ok(blob.bytes)
    } else if url.starts_with("http://") || url.starts_with("https://") {
        fetch_remote(url, cfg).await
    } else {
        // Loose fallback: a bare base64 blob with no data: wrapper.
        let bytes = STANDARD.decode(url.trim()).map_err(|_| {
            AppError::BadRequest(
                "unrecognized image url (expected data:, /v1/files ref, http(s), or base64)".into(),
            )
        })?;
        check_cap(&bytes, cfg)?;
        Ok(bytes)
    }
}

fn check_cap(bytes: &[u8], cfg: &Config) -> Result<(), AppError> {
    if bytes.len() > cfg.max_request_image_bytes {
        return Err(AppError::PayloadTooLarge(format!(
            "exceeds the per-image cap of {} bytes",
            cfg.max_request_image_bytes
        )));
    }
    Ok(())
}

/// The base64 payload of a `data:<mime>;base64,<payload>` URI, or `None` if `url`
/// isn't one.
fn data_uri_payload(url: &str) -> Option<&str> {
    url.strip_prefix("data:")?
        .split_once(";base64,")
        .map(|(_, p)| p)
}

// ---- vision downscale (Ollama-only) ----

/// Build the copy of `messages` that goes to Ollama's vision field, with images
/// over the trigger downscaled to `image_max_dimension`. Returns `None` when no
/// image needs shrinking — the caller then forwards `messages` unchanged, so the
/// plain/text and small-image fast paths stay allocation-free.
///
/// Operates only on `image_url` parts, which after `normalize_request_images` are
/// all full-fidelity `data:` URIs; assistant-text images (generated output) are
/// left alone. A per-image decode failure falls back to the original bytes rather
/// than dropping the image — Ollama gets full-res in the worst case, never garbage.
pub async fn downscale_messages_for_vision(
    messages: &[ChatMessage],
    cfg: &Config,
) -> Option<Vec<ChatMessage>> {
    // Cheap pre-scan (no decode): is anything actually over the trigger?
    let any_oversized = messages.iter().any(|m| {
        let Some(MessageContent::Parts(parts)) = &m.content else {
            return false;
        };
        parts.iter().any(|p| match p {
            ContentPart::ImageUrl { image_url } => data_uri_over_trigger(&image_url.url, cfg),
            _ => false,
        })
    });
    if !any_oversized {
        return None;
    }

    let mut out = messages.to_vec();
    for msg in out.iter_mut() {
        let Some(MessageContent::Parts(parts)) = msg.content.as_mut() else {
            continue;
        };
        for part in parts.iter_mut() {
            if let ContentPart::ImageUrl { image_url } = part {
                if let Some(smaller) = downscale_data_uri(&image_url.url, cfg).await {
                    image_url.url = smaller;
                }
            }
        }
    }
    Some(out)
}

/// Estimate (from base64 length, no decode) whether a `data:` URI's payload is
/// over the downscale trigger. Non-data URIs read as "not over" — by this point
/// every image is an inline data URI anyway.
fn data_uri_over_trigger(url: &str, cfg: &Config) -> bool {
    data_uri_payload(url).is_some_and(|p| p.len() / 4 * 3 > cfg.image_downscale_trigger_bytes)
}

/// Decode + downscale one inline data URI, returning the new data URI. `None` if
/// it isn't an over-trigger data URI or the decode/re-encode fails (keep original).
/// Runs the CPU-heavy decode off the async runtime.
async fn downscale_data_uri(url: &str, cfg: &Config) -> Option<String> {
    let bytes = STANDARD.decode(data_uri_payload(url)?.trim()).ok()?;
    if bytes.len() <= cfg.image_downscale_trigger_bytes {
        return None;
    }
    let (max_dim, cap) = (cfg.image_max_dimension, cfg.max_request_image_bytes);
    let processed = tokio::task::spawn_blocking(move || downscale(bytes, max_dim, cap))
        .await
        .ok()?
        .ok()?;
    let mime = sniff_content_type(&processed);
    Some(format!(
        "data:{mime};base64,{}",
        STANDARD.encode(&processed)
    ))
}

/// Decode, shrink to fit `max_dim` on the longest edge if needed, re-encode
/// (JPEG, or PNG when the image has alpha). Keeps the original bytes if no resize
/// was needed and the re-encode didn't actually shrink it.
fn downscale(bytes: Vec<u8>, max_dim: u32, cap: usize) -> Result<Vec<u8>, AppError> {
    let img = image::load_from_memory(&bytes)
        .map_err(|e| AppError::BadRequest(format!("could not decode image: {e}")))?;
    let needs_resize = img.width().max(img.height()) > max_dim;
    let img = if needs_resize {
        img.resize(max_dim, max_dim, image::imageops::FilterType::Triangle)
    } else {
        img
    };
    let out = encode(&img)?;
    // No resize and re-encoding grew it (e.g. an already-tight JPEG) → keep the
    // original. After a resize the output is always the smaller, correct choice.
    let chosen = if !needs_resize && out.len() >= bytes.len() {
        bytes
    } else {
        out
    };
    if chosen.len() > cap {
        return Err(AppError::PayloadTooLarge(format!(
            "image still exceeds {cap} bytes after downscaling"
        )));
    }
    Ok(chosen)
}

fn encode(img: &image::DynamicImage) -> Result<Vec<u8>, AppError> {
    let mut buf = Vec::new();
    if img.color().has_alpha() {
        img.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png)
            .map_err(|e| AppError::Internal(format!("png encode failed: {e}")))?;
    } else {
        let rgb = img.to_rgb8();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 85)
            .encode_image(&rgb)
            .map_err(|e| AppError::Internal(format!("jpeg encode failed: {e}")))?;
    }
    Ok(buf)
}

// ---- SSRF-guarded remote fetch ----

/// Fetch a remote image, refusing any host that resolves to a private/loopback/
/// link-local address and pinning the connection to the validated IP (so DNS
/// rebinding can't swap in an internal target). Redirects are not followed — a
/// 3xx to an internal resource surfaces as a non-success status. Body is capped.
async fn fetch_remote(url_str: &str, cfg: &Config) -> Result<Vec<u8>, AppError> {
    let url = Url::parse(url_str).map_err(|_| AppError::BadRequest("invalid image URL".into()))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(AppError::BadRequest("unsupported image URL scheme".into()));
    }
    let host = url
        .host_str()
        .ok_or_else(|| AppError::BadRequest("image URL has no host".into()))?
        .to_string();
    let port = url
        .port_or_known_default()
        .unwrap_or(if url.scheme() == "https" { 443 } else { 80 });

    let addr = resolve_allowed(&host, port).await?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_millis(cfg.image_fetch_timeout_ms))
        .resolve(&host, addr)
        .build()
        .map_err(|e| AppError::Internal(format!("image http client build failed: {e}")))?;

    let resp = client
        .get(url.clone())
        .send()
        .await
        .map_err(|e| AppError::BadRequest(format!("failed to fetch image URL: {e}")))?;
    if !resp.status().is_success() {
        return Err(AppError::BadRequest(format!(
            "image URL returned status {}",
            resp.status()
        )));
    }
    let cap = cfg.max_request_image_bytes;
    if let Some(len) = resp.content_length() {
        if len as usize > cap {
            return Err(AppError::PayloadTooLarge(
                "remote image exceeds the per-image cap".into(),
            ));
        }
    }
    let mut stream = resp.bytes_stream();
    let mut buf = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk =
            chunk.map_err(|e| AppError::BadRequest(format!("error reading image body: {e}")))?;
        if buf.len() + chunk.len() > cap {
            return Err(AppError::PayloadTooLarge(
                "remote image exceeds the per-image cap".into(),
            ));
        }
        buf.extend_from_slice(&chunk);
    }
    Ok(buf)
}

/// Resolve `host:port` and return the first address that isn't disallowed.
/// Errors if resolution fails or every address is private/loopback/etc.
async fn resolve_allowed(host: &str, port: u16) -> Result<SocketAddr, AppError> {
    let addrs = tokio::net::lookup_host((host, port))
        .await
        .map_err(|e| AppError::BadRequest(format!("could not resolve image host: {e}")))?;
    for addr in addrs {
        if !ip_is_disallowed(addr.ip()) {
            return Ok(addr);
        }
    }
    Err(AppError::BadRequest(
        "image host resolves only to disallowed (private/loopback/link-local) addresses".into(),
    ))
}

/// Whether an IP must not be fetched from — the SSRF blocklist. Conservative:
/// covers loopback, private, link-local, CGNAT-shared, multicast, unspecified,
/// documentation/reserved ranges, and IPv4-mapped IPv6 (re-checked as v4).
fn ip_is_disallowed(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4_disallowed(v4),
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return v4_disallowed(mapped);
            }
            let seg0 = v6.segments()[0];
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (seg0 & 0xfe00) == 0xfc00 // unique-local fc00::/7
                || (seg0 & 0xffc0) == 0xfe80 // link-local fe80::/10
        }
    }
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
    use crate::config::tests_support::minimal;
    use crate::openai::types::ImageUrl;

    /// Magic-byte PNG header (enough to sniff; not a decodable image — fine for
    /// the pass-through path, which never decodes).
    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

    fn parts_msg(url: &str) -> ChatMessage {
        ChatMessage {
            role: "user".into(),
            content: Some(MessageContent::Parts(vec![ContentPart::ImageUrl {
                image_url: ImageUrl { url: url.into() },
            }])),
            tool_calls: None,
            tool_call_id: None,
            name: None,
        }
    }

    fn url_of(m: &ChatMessage) -> String {
        match m.content.as_ref().unwrap() {
            MessageContent::Parts(p) => match &p[0] {
                ContentPart::ImageUrl { image_url } => image_url.url.clone(),
                _ => panic!("not an image part"),
            },
            _ => panic!("not parts"),
        }
    }

    /// A real, decodable PNG of the given size, as a data URI.
    fn png_data_uri(w: u32, h: u32) -> String {
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::new(w, h));
        let mut buf = Vec::new();
        img.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png)
            .unwrap();
        format!("data:image/png;base64,{}", STANDARD.encode(&buf))
    }

    fn decoded_width(data_uri: &str) -> u32 {
        let payload = data_uri.split_once(";base64,").unwrap().1;
        let bytes = STANDARD.decode(payload).unwrap();
        image::load_from_memory(&bytes).unwrap().width()
    }

    #[tokio::test]
    async fn small_data_uri_passes_through() {
        let b64 = STANDARD.encode(PNG);
        let mut msgs = vec![parts_msg(&format!("data:image/png;base64,{b64}"))];
        normalize_request_images(&mut msgs, &minimal(), None)
            .await
            .unwrap();
        assert_eq!(url_of(&msgs[0]), format!("data:image/png;base64,{b64}"));
    }

    #[tokio::test]
    async fn normalize_never_downscales() {
        // Even with a trigger/dimension that *would* shrink it, the boundary keeps
        // the image at full resolution — downscaling is the vision projection's job.
        let mut cfg = minimal();
        cfg.image_downscale_trigger_bytes = 1;
        cfg.image_max_dimension = 16;
        let mut msgs = vec![parts_msg(&png_data_uri(200, 100))];
        normalize_request_images(&mut msgs, &cfg, None)
            .await
            .unwrap();
        assert_eq!(decoded_width(&url_of(&msgs[0])), 200);
    }

    #[tokio::test]
    async fn vision_projection_downscales_only_when_over_trigger() {
        let mut cfg = minimal();
        cfg.image_downscale_trigger_bytes = 1; // force the trigger
        cfg.image_max_dimension = 64;
        let msgs = vec![parts_msg(&png_data_uri(200, 100))];

        let projected = downscale_messages_for_vision(&msgs, &cfg)
            .await
            .expect("an over-trigger image yields a projection");
        assert_eq!(
            decoded_width(&url_of(&projected[0])),
            64,
            "vision copy shrunk"
        );
        // Source history is left at full resolution.
        assert_eq!(decoded_width(&url_of(&msgs[0])), 200, "original untouched");

        // Under the (default) trigger → no projection, caller reuses `messages`.
        assert!(downscale_messages_for_vision(&msgs, &minimal())
            .await
            .is_none());
    }

    #[tokio::test]
    async fn rejects_non_image() {
        let b64 = STANDARD.encode(b"this is not an image");
        let mut msgs = vec![parts_msg(&format!("data:text/plain;base64,{b64}"))];
        let err = normalize_request_images(&mut msgs, &minimal(), None)
            .await
            .unwrap_err();
        assert!(matches!(err, AppError::BadRequest(m) if m.contains("image #1")));
    }

    #[tokio::test]
    async fn resolves_store_ref_to_inline() {
        let tmp = tempfile::tempdir().unwrap();
        let store = BlobStore::new(tmp.path().to_path_buf(), "k", 3600, 16 << 20, None).unwrap();
        let id = store.put(PNG).await.unwrap();
        let mut msgs = vec![parts_msg(&format!("/v1/files/{id}/content?exp=1&sig=x"))];
        normalize_request_images(&mut msgs, &minimal(), Some(&store))
            .await
            .unwrap();
        assert_eq!(
            url_of(&msgs[0]),
            format!("data:image/png;base64,{}", STANDARD.encode(PNG))
        );
    }

    #[tokio::test]
    async fn missing_store_ref_errors() {
        let tmp = tempfile::tempdir().unwrap();
        let store = BlobStore::new(tmp.path().to_path_buf(), "k", 3600, 16 << 20, None).unwrap();
        let mut msgs = vec![parts_msg("/v1/files/AAAAdoesnotexist/content")];
        let err = normalize_request_images(&mut msgs, &minimal(), Some(&store))
            .await
            .unwrap_err();
        assert!(matches!(err, AppError::BadRequest(m) if m.contains("not found")));
    }

    #[tokio::test]
    async fn oversized_data_uri_rejected_before_decode() {
        let mut cfg = minimal();
        cfg.max_request_image_bytes = 8;
        let b64 = STANDARD.encode(PNG); // 11 bytes > 8
        let mut msgs = vec![parts_msg(&format!("data:image/png;base64,{b64}"))];
        let err = normalize_request_images(&mut msgs, &cfg, None)
            .await
            .unwrap_err();
        assert!(matches!(err, AppError::PayloadTooLarge(_)));
    }

    #[test]
    fn downscale_shrinks_oversized_dimensions() {
        // A real, decodable 2000x1000 image, re-encoded so it's well over a tiny
        // trigger; downscale must bring the long edge down to max_dim.
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::new(2000, 1000));
        let mut src = Vec::new();
        img.write_to(&mut Cursor::new(&mut src), image::ImageFormat::Png)
            .unwrap();
        let out = downscale(src, 512, 16 << 20).unwrap();
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!(decoded.width().max(decoded.height()), 512);
        assert_eq!(decoded.width(), 512);
        assert_eq!(decoded.height(), 256);
    }

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
}
