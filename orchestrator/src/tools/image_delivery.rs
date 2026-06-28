//! How a produced image is handed back to the app (shared by the generation and
//! edit tools).
//!
//! Two modes, chosen per turn from [`TurnContext`]:
//!   * **Reference** — when a blob store is configured *and* the client opted in:
//!     persist the bytes and embed a signed `/v1/images/<id>` URL. Keeps re-sent
//!     history small (FR-O5 URL delivery).
//!   * **Inline** — otherwise (or if the store write fails): a base64 `data:` URI,
//!     the back-compatible form every OpenAI client renders.

use base64::Engine;

use crate::images::BlobStore;
use crate::orchestrator::tools::TurnContext;
use crate::tools::comfy;

/// Build the markdown image the turn appends to the answer for `bytes`.
/// `alt` is the link's alt text (e.g. `"generated"` / `"edited"`).
pub async fn deliver_image(ctx: &TurnContext, bytes: &[u8], mime: &str, alt: &str) -> String {
    if ctx.deliver_image_refs {
        if let Some(store) = ctx.images.as_ref() {
            match store.put(bytes).await {
                Ok(id) => return format!("![{alt}]({})", store.signed_ref(&id)),
                Err(e) => {
                    // A store hiccup must not lose the image — fall back to inline.
                    tracing::warn!(error = %e, "image store write failed; delivering inline");
                }
            }
        }
    }
    format!("![{alt}]({})", comfy::to_data_uri(bytes, mime))
}

/// Spill inline base64 images out of `text` to `store`, replacing each
/// `data:<mime>;base64,…` markdown image target with a stored `/v1/files/<id>`
/// reference. Used to keep multi-MB images out of the in-memory resumable-turn
/// buffer when delivery is inline (no public base, so [`deliver_image`] didn't
/// already store them). [`inline_image_refs`] is the inverse, applied before the
/// bytes reach the client so delivery is byte-for-byte unchanged. On a store
/// failure or unparsable URI the original inline image is left in place.
pub async fn offload_inline_images(text: &str, store: &BlobStore) -> String {
    let targets = link_targets(text, "](data:");
    if targets.is_empty() {
        return text.to_string();
    }
    let mut out = text.to_string();
    // Replace from the end so earlier byte offsets stay valid.
    for (range, uri) in targets.into_iter().rev() {
        let Some((_, bytes)) = parse_data_uri(uri) else {
            continue;
        };
        if let Ok(id) = store.put(&bytes).await {
            out.replace_range(range, &store.signed_ref(&id));
        }
    }
    out
}

/// Inverse of [`offload_inline_images`]: replace each `/v1/files/<id>` markdown
/// image target with the inline base64 `data:` image read back from `store`, so
/// the client receives the same inline form it would have without spilling. A
/// missing/pruned blob leaves the reference untouched (it still loads over the
/// network while fresh).
pub async fn inline_image_refs(text: &str, store: &BlobStore) -> String {
    let targets = link_targets(text, "](");
    if targets.is_empty() {
        return text.to_string();
    }
    let mut out = text.to_string();
    for (range, target) in targets.into_iter().rev() {
        let Some(id) = ref_id(target) else {
            continue;
        };
        if let Some(blob) = store.get(&id).await {
            out.replace_range(range, &comfy::to_data_uri(&blob.bytes, blob.content_type));
        }
    }
    out
}

/// Byte ranges + slices of each markdown link target (`](<target>)`) whose link
/// opener starts with `open`. The range covers just `<target>` (between `](` and
/// `)`), so a caller can `replace_range` it. Returned in source order.
fn link_targets<'a>(text: &'a str, open: &str) -> Vec<(std::ops::Range<usize>, &'a str)> {
    let mut found = Vec::new();
    let mut cursor = 0;
    while let Some(rel) = text[cursor..].find(open) {
        let target_start = cursor + rel + 2; // past the "]("
        let Some(close_rel) = text[target_start..].find(')') else {
            break;
        };
        let target_end = target_start + close_rel;
        found.push((target_start..target_end, &text[target_start..target_end]));
        cursor = target_end + 1;
    }
    found
}

/// Split a `data:<mime>;base64,<payload>` URI into its mime and decoded bytes.
fn parse_data_uri(uri: &str) -> Option<(String, Vec<u8>)> {
    let (mime, b64) = uri.strip_prefix("data:")?.split_once(";base64,")?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    Some((mime.to_string(), bytes))
}

/// Extract the `<id>` from a `…/v1/files/<id>/content…` reference target.
fn ref_id(target: &str) -> Option<String> {
    let marker = "/v1/files/";
    let start = target.find(marker)? + marker.len();
    let id: String = target[start..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    (!id.is_empty()).then_some(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::images::BlobStore;

    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 7, 7];

    fn store(dir: std::path::PathBuf) -> BlobStore {
        BlobStore::new(dir, "k", 3600, 1 << 20, None).unwrap()
    }

    #[tokio::test]
    async fn inline_when_not_opted_in() {
        let ctx = TurnContext::default();
        let md = deliver_image(&ctx, PNG, "image/png", "generated").await;
        assert!(
            md.starts_with("![generated](data:image/png;base64,"),
            "{md}"
        );
    }

    #[tokio::test]
    async fn inline_even_with_store_when_refs_off() {
        let tmp = tempfile::tempdir().unwrap();
        let ctx = TurnContext {
            images: Some(store(tmp.path().to_path_buf())),
            deliver_image_refs: false,
            ..Default::default()
        };
        let md = deliver_image(&ctx, PNG, "image/png", "generated").await;
        assert!(md.contains("data:image/png;base64,"), "{md}");
    }

    #[tokio::test]
    async fn reference_when_opted_in_and_store_present() {
        let tmp = tempfile::tempdir().unwrap();
        let store = store(tmp.path().to_path_buf());
        let ctx = TurnContext {
            images: Some(store.clone()),
            deliver_image_refs: true,
            ..Default::default()
        };
        let md = deliver_image(&ctx, PNG, "image/png", "edited").await;
        assert!(md.starts_with("![edited](/v1/files/"), "{md}");

        // The referenced id resolves back to the stored bytes.
        let id = md
            .split("/v1/files/")
            .nth(1)
            .and_then(|s| s.split('/').next())
            .unwrap();
        assert_eq!(store.get(id).await.unwrap().bytes, PNG);
    }

    #[tokio::test]
    async fn offload_then_inline_roundtrips_inline_image() {
        let tmp = tempfile::tempdir().unwrap();
        let store = store(tmp.path().to_path_buf());
        let original = format!(
            "here is your image\n\n![generated]({}) — enjoy",
            comfy::to_data_uri(PNG, "image/png")
        );

        // Spill: the data URI becomes a compact /v1/files ref; surrounding text
        // and the alt label are preserved.
        let spilled = offload_inline_images(&original, &store).await;
        assert!(spilled.contains("![generated](/v1/files/"), "{spilled}");
        assert!(!spilled.contains("data:image"), "{spilled}");
        assert!(spilled.starts_with("here is your image"));
        assert!(spilled.ends_with("— enjoy"));

        // Re-inline: the client sees byte-for-byte the original markdown back.
        let restored = inline_image_refs(&spilled, &store).await;
        assert_eq!(restored, original);
    }

    #[tokio::test]
    async fn offload_leaves_plain_text_and_non_image_links_untouched() {
        let tmp = tempfile::tempdir().unwrap();
        let store = store(tmp.path().to_path_buf());
        let text = "see [docs](https://example.com) for details";
        assert_eq!(offload_inline_images(text, &store).await, text);
        assert_eq!(inline_image_refs(text, &store).await, text);
    }
}
