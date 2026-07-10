import Foundation

/// Deletes server-hosted image blobs (`DELETE /v1/files/<id>`, bearer-authed)
/// when their conversation is deleted, so the app owns the images' lifecycle
/// (spec §2.2b). Best-effort: failures are swallowed because the server's TTL
/// pruner is the backstop for blobs that never get an explicit delete.
public struct ImageClient: Sendable {
    private let session: URLSession
    private let maxResponseBytes: Int

    public init(session: URLSession = .shared, maxResponseBytes: Int = 20 * 1024 * 1024) {
        self.session = session
        self.maxResponseBytes = maxResponseBytes
    }

    /// Fetch a signed image URL's bytes + content type while it's fresh, so the
    /// app can cache it locally. `nil` on any failure (caller falls back to
    /// loading the URL directly until it expires).
    public func fetch(_ url: URL, trustedBase: URL) async -> ServerImageRef.CachedImage? {
        guard ServerImageRef.isTrustedContentURL(url, backendBase: trustedBase) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                .split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard mime.lowercased().hasPrefix("image/"),
                  response.expectedContentLength <= 0
                    || response.expectedContentLength <= Int64(maxResponseBytes)
            else { return nil }
            var data = Data()
            data.reserveCapacity(min(maxResponseBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maxResponseBytes else { return nil }
                data.append(byte)
            }
            return ServerImageRef.CachedImage(data: data, mime: mime)
        } catch {
            return nil
        }
    }

    /// Source-compatible explicit-fetch overload. Automatic markdown loading
    /// uses the `trustedBase` variant; a direct caller has already chosen this
    /// URL, so its own origin is the trust boundary as in previous releases.
    public func fetch(_ url: URL) async -> ServerImageRef.CachedImage? {
        await fetch(url, trustedBase: url)
    }

    /// Fire a DELETE for each id against `base` in bounded batches. Best-effort.
    public func delete(
        ids: [String], base: URL, token: String, maxConcurrency: Int = 8
    ) async {
        let unique = Array(Set(ids))
        let width = max(1, maxConcurrency)
        for start in stride(from: 0, to: unique.count, by: width) {
            let end = min(unique.count, start + width)
            await withTaskGroup(of: Void.self) { group in
                for id in unique[start..<end] {
                    group.addTask { await deleteOne(id, base: base, token: token) }
                }
            }
        }
    }

    private func deleteOne(_ id: String, base: URL, token: String) async {
        var req = URLRequest(url: base.appendingPathComponent("v1/files/\(id)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 8
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await session.data(for: req)
    }
}
