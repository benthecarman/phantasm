//! Server-hosted image blobs (the storage half of FR-O5's URL delivery).
//!
//! When `IMAGE_STORE_DIR` (plus `PUBLIC_BASE_URL`) is configured, generated/
//! edited images are persisted here and handed to the app as **signed,
//! Files-style URLs** (`/v1/files/<id>/content`) instead of inline base64, so a
//! re-sent conversation history stays small (it carries short links, not
//! multi-MB data URIs).
//!
//! Protection model:
//!   * **Random opaque ids** (UUID): non-enumerable and unique per delivery, so
//!     deleting one conversation can never invalidate an identical image owned
//!     by another. Legacy content-hash ids remain readable.
//!   * **Signed URLs** (HMAC-SHA256 over `id:exp`, keyed by the server's auth
//!     token): the fetch route is exempt from bearer auth — markdown image
//!     loaders can't send an `Authorization` header — so a valid, unexpired
//!     signature is what authorizes a read. The random id prevents enumeration;
//!     the signature + expiry enforce access and lifetime.
//!   * **Lifecycle**: the app deletes a blob when its conversation is deleted
//!     (`DELETE /v1/files/<id>`); a lazy TTL pruner (`IMAGE_STORE_TTL_S`) is the
//!     backstop for deletes that never arrive (uninstall, lost request).

use std::io::Write;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

const B64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::URL_SAFE_NO_PAD;

/// A filesystem-backed image store. Cheap to clone (`Arc`).
#[derive(Clone)]
pub struct BlobStore {
    inner: Arc<Inner>,
}

struct Inner {
    dir: PathBuf,
    /// Signing key bytes. Authenticated deployments default to the existing
    /// bearer token for compatibility; open deployments persist a random key.
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

    /// Persist `bytes`, returning a unique opaque id. Unique ids intentionally
    /// avoid cross-conversation ownership ambiguity for identical images.
    /// Prunes expired blobs opportunistically.
    pub async fn put(&self, bytes: &[u8]) -> std::io::Result<String> {
        if bytes.len() > self.inner.max_bytes {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "image exceeds store byte cap",
            ));
        }
        let id = uuid::Uuid::new_v4().simple().to_string();
        let path = self.path_for(&id).expect("generated id is always valid");
        // Temp file + rename so a concurrent reader never sees a partial blob.
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
        let content_type = sniff_stored_content_type(&bytes);
        Some(Blob {
            bytes,
            content_type,
        })
    }

    /// Stored byte length without loading the blob. Used to resolve HTTP range
    /// requests before reading a video-sized artifact.
    pub async fn len(&self, id: &str) -> Option<usize> {
        let path = self.path_for(id)?;
        tokio::fs::metadata(path).await.ok()?.len().try_into().ok()
    }

    /// Read one inclusive byte range while sniffing the type from the file
    /// prefix. Avoids loading a whole video for every AVPlayer range request.
    pub async fn get_range(&self, id: &str, start: usize, end: usize) -> Option<Blob> {
        let path = self.path_for(id)?;
        tokio::task::spawn_blocking(move || {
            if end < start {
                return None;
            }
            let mut file = std::fs::File::open(path).ok()?;
            let mut prefix = [0u8; 16];
            let prefix_len = file.read(&mut prefix).ok()?;
            let content_type = sniff_stored_content_type(&prefix[..prefix_len]);
            file.seek(SeekFrom::Start(start as u64)).ok()?;
            let len = end.checked_sub(start)?.checked_add(1)?;
            let mut bytes = vec![0; len];
            file.read_exact(&mut bytes).ok()?;
            Some(Blob {
                bytes,
                content_type,
            })
        })
        .await
        .ok()
        .flatten()
    }

    /// Delete a blob by id. `Ok(true)` if a file was removed, `Ok(false)` if the
    /// id was malformed or already gone (idempotent).
    pub async fn delete(&self, id: &str) -> std::io::Result<bool> {
        // Pre-unique stores used one 43-character content hash for every
        // identical image, so ownership is unknowable. Keep those legacy blobs
        // until TTL rather than let deleting one old conversation break another.
        if id.len() != 32 {
            return Ok(false);
        }
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

    /// Resolve an id to its on-disk path, rejecting anything outside the legacy
    /// hash/new UUID shared charset and length bound — the traversal guard.
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
                let Ok(entry) = entry else { continue };
                let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                    continue;
                };
                if name == SIGNING_KEY_FILE || name.starts_with(".write-probe-") {
                    continue;
                }
                let Ok(meta) = entry.metadata() else {
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

    /// Periodically prune even when no new images are generated. The prior lazy
    /// put-time pruning left expired stores untouched on otherwise-idle servers.
    pub fn spawn_pruner(&self, interval: std::time::Duration) {
        let store = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(interval);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tick.tick().await;
                store.prune().await;
            }
        });
    }
}

const SIGNING_KEY_FILE: &str = ".signing-key";

/// Resolve a stable HMAC key without changing authenticated deployments:
/// explicit `IMAGE_SIGNING_KEY`, then an already-persisted tokenless key, then
/// the existing auth token, otherwise a new key persisted beside the blobs.
pub fn resolve_signing_key(
    dir: &Path,
    configured: Option<&str>,
    auth_token: Option<&str>,
) -> std::io::Result<String> {
    if let Some(key) = configured.filter(|key| !key.trim().is_empty()) {
        return Ok(key.to_string());
    }
    std::fs::create_dir_all(dir)?;
    let path = dir.join(SIGNING_KEY_FILE);
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let existing = existing.trim();
        if !existing.is_empty() {
            return Ok(existing.to_string());
        }
    }
    if let Some(key) = auth_token.filter(|key| !key.trim().is_empty()) {
        return Ok(key.to_string());
    }

    let generated = format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    );
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    match options.open(&path) {
        Ok(mut file) => {
            file.write_all(generated.as_bytes())?;
            file.sync_all()?;
            Ok(generated)
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let existing = std::fs::read_to_string(path)?;
            let existing = existing.trim();
            if existing.is_empty() {
                Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "image signing key file is empty",
                ))
            } else {
                Ok(existing.to_string())
            }
        }
        Err(e) => Err(e),
    }
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

pub(crate) fn recognized_audio_type(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"fLaC") {
        return Some("audio/flac");
    }
    if bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WAVE" {
        return Some("audio/wav");
    }
    if bytes.starts_with(b"OggS") {
        return Some("audio/ogg");
    }
    if bytes.starts_with(b"ID3")
        || (bytes.len() >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
    {
        return Some("audio/mpeg");
    }
    None
}

/// Generated artifact type identified from magic bytes. The image subset stays
/// unchanged for request-image validation; media is accepted only for generated
/// server-hosted artifacts.
pub(crate) fn recognized_artifact_type(bytes: &[u8]) -> Option<&'static str> {
    recognized_image_type(bytes)
        .or_else(|| recognized_audio_type(bytes))
        .or_else(|| {
            if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
                Some("video/mp4")
            } else if bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
                Some("video/webm")
            } else {
                None
            }
        })
}

/// Identify the image type from magic bytes; defaults to PNG (ComfyUI's usual
/// output) when unrecognized. Returned as a `&'static str` content-type.
pub(crate) fn sniff_content_type(bytes: &[u8]) -> &'static str {
    recognized_image_type(bytes).unwrap_or("image/png")
}

fn sniff_stored_content_type(bytes: &[u8]) -> &'static str {
    recognized_artifact_type(bytes).unwrap_or("application/octet-stream")
}

fn prune_dir(dir: &Path, ttl_s: u64) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let now = SystemTime::now();
    let mut removed = 0;
    for entry in entries.flatten() {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if name == SIGNING_KEY_FILE || name.starts_with(".write-probe-") {
            continue;
        }
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
    async fn put_get_roundtrip_uses_unique_ownership_ids() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path().to_path_buf());
        let id1 = s.put(PNG).await.unwrap();
        let id2 = s.put(PNG).await.unwrap();
        assert_ne!(
            id1, id2,
            "each delivery owns an independently deletable blob"
        );
        let blob = s.get(&id1).await.unwrap();
        assert_eq!(blob.bytes, PNG);
        assert_eq!(blob.content_type, "image/png");
    }

    #[tokio::test]
    async fn range_read_returns_only_requested_media_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path().to_path_buf());
        let bytes = b"fLaC-audio-payload";
        let id = s.put(bytes).await.unwrap();
        assert_eq!(s.len(&id).await, Some(bytes.len()));
        let range = s.get_range(&id, 5, 9).await.unwrap();
        assert_eq!(range.bytes, b"audio");
        assert_eq!(range.content_type, "audio/flac");
    }

    #[tokio::test]
    async fn tokenless_signing_key_persists_and_is_not_counted_or_pruned() {
        let tmp = tempfile::tempdir().unwrap();
        let first = resolve_signing_key(tmp.path(), None, None).unwrap();
        let second = resolve_signing_key(tmp.path(), None, None).unwrap();
        assert_eq!(first, second);
        let s = BlobStore::new(tmp.path().to_path_buf(), &first, 0, 1 << 20, None).unwrap();
        let usage = s.usage().await.unwrap();
        assert_eq!(usage.files, 0);
        s.prune().await;
        assert!(tmp.path().join(SIGNING_KEY_FILE).exists());
        assert_eq!(
            resolve_signing_key(tmp.path(), Some("explicit"), Some("auth")).unwrap(),
            "explicit"
        );
        let auth_tmp = tempfile::tempdir().unwrap();
        assert_eq!(
            resolve_signing_key(auth_tmp.path(), None, Some("auth")).unwrap(),
            "auth"
        );
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

    #[tokio::test]
    async fn explicit_delete_preserves_legacy_shared_hash_ids() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path().to_path_buf());
        let legacy = "a".repeat(43);
        tokio::fs::write(s.path_for(&legacy).unwrap(), PNG)
            .await
            .unwrap();
        assert!(!s.delete(&legacy).await.unwrap());
        assert!(
            s.get(&legacy).await.is_some(),
            "legacy refs rely on TTL cleanup"
        );
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

    #[test]
    fn sniffs_generated_video_types() {
        assert_eq!(recognized_artifact_type(b"....ftypisom"), Some("video/mp4"));
        assert_eq!(
            recognized_artifact_type(&[0x1A, 0x45, 0xDF, 0xA3]),
            Some("video/webm")
        );
    }

    #[test]
    fn sniffs_generated_audio_types() {
        assert_eq!(recognized_artifact_type(b"fLaCdata"), Some("audio/flac"));
        assert_eq!(
            recognized_artifact_type(b"RIFF....WAVEfmt "),
            Some("audio/wav")
        );
        assert_eq!(recognized_artifact_type(b"OggSdata"), Some("audio/ogg"));
        assert_eq!(recognized_artifact_type(b"ID3data"), Some("audio/mpeg"));
    }
}
