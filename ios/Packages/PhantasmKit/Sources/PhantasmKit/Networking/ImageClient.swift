import Foundation

/// Deletes server-hosted image blobs (`DELETE /v1/files/<id>`, bearer-authed)
/// when their conversation is deleted, so the app owns the images' lifecycle
/// (spec §2.2b). Best-effort: failures are swallowed because the server's TTL
/// pruner is the backstop for blobs that never get an explicit delete.
public struct ImageClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fire a DELETE for each id against `base`. Concurrent and best-effort.
    public func delete(ids: [String], base: URL, token: String) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await deleteOne(id, base: base, token: token) }
            }
        }
    }

    private func deleteOne(_ id: String, base: URL, token: String) async {
        var req = URLRequest(url: base.appendingPathComponent("v1/files/\(id)"))
        req.httpMethod = "DELETE"
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await session.data(for: req)
    }
}
