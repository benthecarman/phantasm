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

        if let (data, response) = try? await session.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let caps = try? Wire.decoder().decode(Capabilities.self, from: data) {
            return .full(caps)
        }
        // Not an orchestrator (or unreachable) — degrade, discovering models if we can.
        let models = await fetchModelList(base: base, token: token)
        return .plainChatOnly(models: models)
    }

    /// Validate reachability + auth for the Settings "Test connection" button
    /// (FR-A1). Tries capabilities first; if that 404s (bare Ollama) confirms the
    /// backend by listing `/v1/models` — no model name required, no generation.
    public func validate(base: URL, token: String) async -> Result<BackendMode, AppError> {
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
                let models = await fetchModelList(base: base, token: token)
                return .success(.plainChatOnly(models: models))
            case 401, 403:
                return .failure(.authFailed)
            case 404:
                // Not our orchestrator — confirm it's an OpenAI-compatible backend.
                return await confirmPlainBackend(base: base, token: token)
            default:
                return .failure(.modelError("HTTP \(http.statusCode)"))
            }
        } catch {
            return .failure(.from(error))
        }
    }

    /// Discover available model ids for the picker. Uses the orchestrator
    /// manifest when present, otherwise bare `/v1/models`. Empty on failure.
    public func models(base: URL, token: String) async -> [String] {
        await probe(base: base, token: token).models
    }

    /// Confirm a bare backend by listing models. Distinguishes auth failure from
    /// "reachable but not an OpenAI-compatible endpoint".
    private func confirmPlainBackend(base: URL, token: String) async -> Result<BackendMode, AppError> {
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            switch http.statusCode {
            case 200:
                let models = decodeModelIDs(data)
                return .success(.plainChatOnly(models: models))
            case 401, 403:
                return .failure(.authFailed)
            default:
                return .failure(.modelError("Not an OpenAI-compatible endpoint (HTTP \(http.statusCode))"))
            }
        } catch {
            return .failure(.from(error))
        }
    }

    /// Best-effort model list (empty on any failure).
    private func fetchModelList(base: URL, token: String) async -> [String] {
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }
        return decodeModelIDs(data)
    }

    private func decodeModelIDs(_ data: Data) -> [String] {
        (try? JSONDecoder().decode(ModelsResponse.self, from: data))?.data.map(\.id) ?? []
    }

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }
}
