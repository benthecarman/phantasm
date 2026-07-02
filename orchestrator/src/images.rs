//! Server-hosted image blobs (the storage half of FR-O5's URL delivery).
//!
//! When `IMAGE_STORE_DIR` (plus `PUBLIC_BASE_URL`) is configured, generated/
//! edited images are persisted here and handed to the app as **signed,
//! Files-style URLs** (`/v1/files/<id>/content`) instead of inline base64, so a
//! re-sent conversation history stays small (it carries short links, not
//! multi-MB data URIs).
//!
//! Protection model:
//!   * **Content-hash ids** (sha256 → base64url): opaque, non-enumerable, and
//!     self-deduplicating. Validated to a fixed charset so an id can never
//!     escape the store directory (no path traversal).
//!   * **Signed URLs** (HMAC-SHA256 over `id:exp`, keyed by the server's auth
//!     token): the fetch route is exempt from bearer auth — markdown image
//!     loaders can't send an `Authorization` header — so a valid, unexpired
//!     signature is what authorizes a read. The content-hash id is the primary
//!     guard; the signature + expiry (the URL expires with the blob, governed by
//!     `IMAGE_STORE_TTL_S`) are defense-in-depth.
//!   * **Lifecycle**: the app deletes a blob when its conversation is deleted
//!     (`DELETE /v1/files/<id>`); a lazy TTL pruner (`IMAGE_STORE_TTL_S`) is the
//!     backstop for deletes that never arrive (uninstall, lost request).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

const B64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::URL_SAFE_NO_PAD;

/// A filesystem-backed, content-addressed image store. Cheap to clone (`Arc`).
#[derive(Clone)]
pub struct BlobStore {
    inner: Arc<Inner>,
}

struct Inner {
    dir: PathBuf,
    /// Signing key (the server auth token's bytes). Rotating the token
    /// invalidates outstanding URLs — acceptable; the app re-fetches on next view
    /// and the content-hash id still gates access.
    key: Vec<u8>,
    store_ttl_s: u64,
    max_bytes: usize,
    /// Absolute origin for minted links, or `None` to emit site-relative paths.
    public_base: Option<String>,
}

/// A stored image: raw bytes plus the sniffed content type.
pub struct Blob {
    pub bytes: Vec<u8>,
    pub content_type: &'static str,
}

/// What the store currently holds on disk — for the dashboard.
#[derive(Debug, serde::Serialize)]
pub struct StoreUsage {
    pub files: u64,
    pub bytes: u64,
}

impl BlobStore {
    /// Build a store rooted at `dir`, creating it if needed. `key` is the HMAC
    /// signing key (the server auth token). Returns `Err` so startup can fail
    /// fast on an unwritable directory rather than silently degrading to inline
    /// delivery on every image (see `deliver_image`'s write-failure fallback).
    pub fn new(
        dir: PathBuf,
        key: &str,
        store_ttl_s: u64,
        max_bytes: usize,
        public_base: Option<&url::Url>,
    ) -> std::io::Result<Self> {
        std::fs::create_dir_all(&dir)?;
        // `create_dir_all` is a no-op that *succeeds* when the directory already
        // exists, so it can't tell us the directory is actually writable — a
        // read-only mount (e.g. systemd `ProtectSystem=strict` without a
        // `ReadWritePaths`/`StateDirectory` for it) or a root-owned dir under a
        // non-root service user both slip past it. Probe with a real write +
        // remove so an unwritable store surfaces at boot, not as a silent
        // per-image fallback that looks exactly like having no store at all.
        let probe = dir.join(format!(".write-probe-{}", uuid::Uuid::new_v4().simple()));
        std::fs::write(&probe, b"")?;
        let _ = std::fs::remove_file(&probe);
        Ok(BlobStore {
            inner: Arc::new(Inner {
                dir,
                key: key.as_bytes().to_vec(),
                store_ttl_s,
                max_bytes,
                // Trim a trailing slash so we can join with "/v1/..." uniformly.
                public_base: public_base.map(|u| u.as_str().trim_end_matches('/').to_string()),
            }),
        })
    }

    /// Persist `bytes`, returning the content-hash id. Idempotent: identical
    /// bytes map to the same id and file. Prunes expired blobs opportunistically.
    pub async fn put(&self, bytes: &[u8]) -> std::io::Result<String> {
        if bytes.len() > self.inner.max_bytes {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "image exceeds store byte cap",
            ));
        }
        let id = content_id(bytes);
        let path = self.path_for(&id).expect("content id is always valid");
        // Write only if absent (dedup) — and via a temp file + rename so a
        // concurrent reader never sees a half-written blob.
        if tokio::fs::try_exists(&path).await.unwrap_or(false) {
            return Ok(id);
        }
        let tmp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4().simple()));
        tokio::fs::write(&tmp, bytes).await?;
        tokio::fs::rename(&tmp, &path).await?;
        self.prune().await;
        Ok(id)
    }

    /// Fetch a blob by id, sniffing its content type. `None` if the id is
    /// malformed or absent.
    pub async fn get(&self, id: &str) -> Option<Blob> {
        let path = self.path_for(id)?;
        let bytes = tokio::fs::read(&path).await.ok()?;
        let content_type = sniff_content_type(&bytes);
        Some(Blob {
            bytes,
            content_type,
        })
    }

    /// Delete a blob by id. `Ok(true)` if a file was removed, `Ok(false)` if the
    /// id was malformed or already gone (idempotent).
    pub async fn delete(&self, id: &str) -> std::io::Result<bool> {
        let Some(path) = self.path_for(id) else {
            return Ok(false);
        };
        match tokio::fs::remove_file(&path).await {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// Whether absolute URLs can be minted (a public origin is configured). URL
    /// delivery is gated on this so the app only ever receives standard,
    /// directly-loadable absolute image URLs — never a relative path it would
    /// have to resolve itself.
    pub fn has_public_base(&self) -> bool {
        self.inner.public_base.is_some()
    }

    /// The signed reference to embed for `id` (OpenAI Files-style content path):
    /// `<base>/v1/files/<id>/content?exp=&sig=`, site-relative when no public base
    /// is configured. The URL expires with the blob (`store_ttl_s`) — one
    /// lifetime, since a link to a pruned blob is useless anyway.
    pub fn signed_ref(&self, id: &str) -> String {
        let exp = now_s() + self.inner.store_ttl_s;
        let sig = self.sign(id, exp);
        let base = self.inner.public_base.as_deref().unwrap_or("");
        format!("{base}/v1/files/{id}/content?exp={exp}&sig={sig}")
    }

    /// Validate a fetch URL's signature: the signature must match and `exp` must
    /// be in the future. Constant-time compare; no distinction between a bad and
    /// an expired signature to the caller (both => deny).
    pub fn verify(&self, id: &str, exp: u64, sig: &str) -> bool {
        if exp < now_s() {
            return false;
        }
        let expected = self.sign(id, exp);
        constant_time_eq(expected.as_bytes(), sig.as_bytes())
    }

    fn sign(&self, id: &str, exp: u64) -> String {
        let mut mac =
            HmacSha256::new_from_slice(&self.inner.key).expect("HMAC accepts any key length");
        mac.update(id.as_bytes());
        mac.update(b":");
        mac.update(exp.to_string().as_bytes());
        B64.encode(mac.finalize().into_bytes())
    }

    /// Resolve an id to its on-disk path, rejecting any id that isn't our exact
    /// base64url content-hash shape — the path-traversal guard.
    fn path_for(&self, id: &str) -> Option<PathBuf> {
        is_valid_id(id).then(|| self.inner.dir.join(id))
    }

    /// Sum the store directory's current file count and bytes. Best-effort
    /// (`None` on an unreadable dir); the store is flat, so a plain scan is
    /// the whole story.
    pub async fn usage(&self) -> Option<StoreUsage> {
        let dir = self.inner.dir.clone();
        tokio::task::spawn_blocking(move || {
            let mut usage = StoreUsage { files: 0, bytes: 0 };
            for entry in std::fs::read_dir(&dir).ok()? {
                let Ok(meta) = entry.and_then(|e| e.metadata()) else {
                    continue;
                };
                if meta.is_file() {
                    usage.files += 1;
                    usage.bytes += meta.len();
                }
            }
            Some(usage)
        })
        .await
        .ok()
        .flatten()
    }

    /// Remove blobs older than the store TTL. Best-effort: scan errors and
    /// individual stat/remove failures are logged at debug and skipped.
    async fn prune(&self) {
        let dir = self.inner.dir.clone();
        let ttl = self.inner.store_ttl_s;
        let removed = tokio::task::spawn_blocking(move || prune_dir(&dir, ttl))
            .await
            .unwrap_or(0);
        if removed > 0 {
            tracing::debug!(removed, "pruned expired image blobs");
        }
    }
}

/// sha256(bytes) as base64url — a 43-char opaque, collision-resistant id.
fn content_id(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    B64.encode(digest)
}

/// A valid id is exactly the base64url alphabet, non-empty, and length-bounded
/// (a sha256 digest is 43 base64url chars). This is what keeps `dir.join(id)`
/// inside the store: no `/`, no `.`, no `..`.
fn is_valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The image type identified from magic bytes, or `None` if the bytes aren't a
/// format we recognize. The strict check used when an unknown blob must be
/// rejected (e.g. validating an upload) rather than assumed.
pub(crate) fn recognized_image_type(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

/// Identify the image type from magic bytes; defaults to PNG (ComfyUI's usual
/// output) when unrecognized. Returned as a `&'static str` content-type.
pub(crate) fn sniff_content_type(bytes: &[u8]) -> &'static str {
    recognized_image_type(bytes).unwrap_or("image/png")
}

fn prune_dir(dir: &Path, ttl_s: u64) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let now = SystemTime::now();
    let mut removed = 0;
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let expired = meta
            .modified()
            .ok()
            .and_then(|m| now.duration_since(m).ok())
            .map(|age| age.as_secs() > ttl_s)
            .unwrap_or(false);
        if expired && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    removed
}

fn now_s() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Constant-time byte comparison (avoid leaking the signature via timing).
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
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

    fn store(dir: PathBuf) -> BlobStore {
        BlobStore::new(dir, "test-key", 3600, 16 * 1024 * 1024, None).unwrap()
    }

    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

    #[tokio::test]
    async fn put_get_roundtrip_and_dedup() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path().to_path_buf());
        let id1 = s.put(PNG).await.unwrap();
        let id2 = s.put(PNG).await.unwrap();
        assert_eq!(id1, id2, "identical bytes dedupe to one id");
        let blob = s.get(&id1).await.unwrap();
        assert_eq!(blob.bytes, PNG);
        assert_eq!(blob.content_type, "image/png");
    }

    #[tokio::test]
    async fn delete_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path().to_path_buf());
        let id = s.put(PNG).await.unwrap();
        assert!(s.delete(&id).await.unwrap(), "first delete removes");
        assert!(!s.delete(&id).await.unwrap(), "second delete is a no-op");
        assert!(s.get(&id).await.is_none());
    }

    #[cfg(unix)]
    #[test]
    fn new_fails_fast_on_unwritable_dir() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("ro");
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o555)).unwrap();

        // Root bypasses permission bits, so the probe would succeed and there'd
        // be nothing to assert — detect that by trying a write ourselves and
        // skip rather than claim a guarantee the environment can't uphold.
        if std::fs::write(dir.join(".root-check"), b"").is_ok() {
            let _ = std::fs::remove_file(dir.join(".root-check"));
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
            return;
        }

        match BlobStore::new(dir.clone(), "k", 3600, 1 << 20, None) {
            Ok(_) => panic!("a read-only store dir must fail at construction"),
            Err(e) => assert_eq!(e.kind(), std::io::ErrorKind::PermissionDenied),
        }

        // Restore perms so the tempdir can clean itself up.
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[tokio::test]
    async fn rejects_oversized_put() {
        let tmp = tempfile::tempdir().unwrap();
        let s = BlobStore::new(tmp.path().to_path_buf(), "k", 3600, 4, None).unwrap();
        assert!(s.put(PNG).await.is_err(), "11 bytes over a 4-byte cap");
    }

    #[test]
    fn rejects_traversal_ids() {
        assert!(!is_valid_id("../etc/passwd"));
        assert!(!is_valid_id("a/b"));
        assert!(!is_valid_id("a.b"));
        assert!(!is_valid_id(""));
        assert!(is_valid_id("abcDEF123-_"));
    }

    #[test]
    fn signature_roundtrips_and_rejects_tampering() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path().to_path_buf());
        let exp = now_s() + 3600;
        let sig = s.sign("abc", exp);
        assert!(s.verify("abc", exp, &sig));
        assert!(!s.verify("abc", exp, "bogus"), "bad signature denied");
        assert!(!s.verify("abd", exp, &sig), "id mismatch denied");
        assert!(!s.verify("abc", exp - 1, &sig), "exp is part of the MAC");
    }

    #[test]
    fn expired_url_is_denied() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path().to_path_buf());
        let exp = now_s() - 1; // already in the past
        let sig = s.sign("abc", exp);
        assert!(!s.verify("abc", exp, &sig), "expired even with a valid sig");
    }

    #[test]
    fn signed_ref_shapes() {
        let tmp = tempfile::tempdir().unwrap();
        // Relative when no public base.
        let s = store(tmp.path().to_path_buf());
        assert!(!s.has_public_base());
        assert!(s
            .signed_ref("abc")
            .starts_with("/v1/files/abc/content?exp="));

        // Absolute (trailing slash trimmed) when configured.
        let base = url::Url::parse("https://host.example/").unwrap();
        let s2 = BlobStore::new(tmp.path().to_path_buf(), "k", 3600, 1 << 20, Some(&base)).unwrap();
        assert!(s2.has_public_base());
        assert!(s2
            .signed_ref("abc")
            .starts_with("https://host.example/v1/files/abc/content?exp="));
    }

    #[tokio::test]
    async fn prune_removes_expired_only() {
        let tmp = tempfile::tempdir().unwrap();
        let s = BlobStore::new(tmp.path().to_path_buf(), "k", 5, 1 << 20, None).unwrap();

        // A fresh blob survives.
        let fresh = s.put(PNG).await.unwrap();
        // An aged blob (backdate its mtime past the 5s TTL) is pruned.
        let aged = s
            .put(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 9])
            .await
            .unwrap();
        let aged_path = s.path_for(&aged).unwrap();
        std::fs::File::options()
            .write(true)
            .open(&aged_path)
            .unwrap()
            .set_modified(SystemTime::now() - std::time::Duration::from_secs(60))
            .unwrap();

        s.prune().await;
        assert!(s.get(&fresh).await.is_some(), "fresh blob kept");
        assert!(s.get(&aged).await.is_none(), "expired blob pruned");
    }

    #[test]
    fn sniffs_common_image_types() {
        assert_eq!(sniff_content_type(PNG), "image/png");
        assert_eq!(sniff_content_type(&[0xFF, 0xD8, 0xFF, 0]), "image/jpeg");
        assert_eq!(sniff_content_type(b"GIF89a..."), "image/gif");
        let webp = b"RIFF\0\0\0\0WEBPVP8 ";
        assert_eq!(sniff_content_type(webp), "image/webp");
        assert_eq!(sniff_content_type(b"unknown"), "image/png");
    }
}
