import Foundation

/// Probes `/v1/capabilities` and resolves a `BackendMode` (FR-A2). A 404 or
/// connection failure degrades to `.plainChatOnly` rather than erroring, so the
/// app stays usable against a bare Ollama.
public struct CapabilitiesClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func probe(base: URL, token: String) async -> BackendMode {
        var req = URLRequest(url: base.appendingPathComponent("v1/capabilities"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            return .plainChatOnly
        }
        guard http.statusCode == 200,
              let caps = try? Wire.decoder().decode(Capabilities.self, from: data) else {
            return .plainChatOnly
        }
        return .full(caps)
    }

    /// Validate reachability + auth for the Settings "Test connection" button
    /// (FR-A1). Tries capabilities first; if that 404s (bare Ollama) falls back
    /// to a tiny non-streaming chat ping to confirm the token works.
    public func validate(base: URL, token: String, pingModel: String) async -> Result<BackendMode, AppError> {
        var req = URLRequest(url: base.appendingPathComponent("v1/capabilities"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            switch http.statusCode {
            case 200:
                if let caps = try? Wire.decoder().decode(Capabilities.self, from: data) {
                    return .success(.full(caps))
                }
                return .success(.plainChatOnly)
            case 401, 403:
                return .failure(.authFailed)
            case 404:
                // Not an orchestrator — confirm auth with a chat ping.
                return await pingChat(base: base, token: token, model: pingModel)
            default:
                return .failure(.modelError("HTTP \(http.statusCode)"))
            }
        } catch {
            return .failure(.from(error))
        }
    }

    private func pingChat(base: URL, token: String, model: String) async -> Result<BackendMode, AppError> {
        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        let body = ChatRequest(model: model, messages: [WireMessage(role: "user", content: "ping")], stream: false)
        req.httpBody = try? Wire.encoder().encode(body)

        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            if let err = AppError.fromStatus(http.statusCode) { return .failure(err) }
            return .success(.plainChatOnly)
        } catch {
            return .failure(.from(error))
        }
    }
}
