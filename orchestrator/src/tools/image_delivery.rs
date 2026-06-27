//! How a produced image is handed back to the app (shared by the generation and
//! edit tools).
//!
//! Two modes, chosen per turn from [`TurnContext`]:
//!   * **Reference** — when a blob store is configured *and* the client opted in:
//!     persist the bytes and embed a signed `/v1/images/<id>` URL. Keeps re-sent
//!     history small (FR-O5 URL delivery).
//!   * **Inline** — otherwise (or if the store write fails): a base64 `data:` URI,
//!     the back-compatible form every OpenAI client renders.

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::images::BlobStore;

    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 7, 7];

    fn store(dir: std::path::PathBuf) -> BlobStore {
        BlobStore::new(dir, "k", 3600, 3600, 1 << 20, None).unwrap()
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
}
