import Foundation

/// Best-effort model preload, fired on launch / backend switch so the first
/// turn skips cold-start. Always silent: warming a backend that is down or slow
/// must never surface an error or block the UI.
///
/// - `.full`: hits the orchestrator's `POST /v1/warm` (which loads upstream
///   Ollama when applicable, no-op otherwise).
/// - `.ollamaNative`: issues a native `/api/chat` "load" (empty messages →
///   model resident, zero tokens) with an explicit warm-only `keep_alive`.
/// - `.plainChatOnly`: skipped — a generic/hosted OpenAI endpoint has no free
///   preload and warming it could cost tokens.
public struct WarmupClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func warm(model: String, base: URL, token: String, mode: BackendMode) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch mode {
        case .full:
            await post(
                path: "v1/warm",
                body: ["model": trimmed],
                base: base,
                token: token
            )
        case .ollamaNative:
            await post(
                path: "api/chat",
                body: ["model": trimmed, "messages": [], "keep_alive": "30m"],
                base: base,
                token: token
            )
        case .plainChatOnly:
            break
        }
    }

    private func post(path: String, body: [String: Any], base: URL, token: String) async {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // A preload can be slow on a true cold cache; give it room but don't wait
        // forever. Discard the result either way — this is fire-and-forget.
        req.timeoutInterval = 60
        _ = try? await session.data(for: req)
    }
}
