import Foundation

/// Resolves a backend by trying the Phantasm capabilities manifest first, then
/// falling back to native Ollama and generic OpenAI-compatible model listing.
public struct CapabilitiesClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Resolve reachability + auth without generating text. This is used by both
    /// background probing and the Settings "Test Connection" buttons.
    public func resolve(base: URL, token: String) async -> Result<BackendMode, AppError> {
        var req = URLRequest(url: base.appendingPathComponent("v1/capabilities"))
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            switch http.statusCode {
            case 200:
                if let caps = try? Wire.decoder().decode(Capabilities.self, from: data) {
                    return .success(.full(caps))
                }
                return await confirmPlainBackend(base: base, token: token)
            case 401, 403:
                return .failure(.authFailed)
            default:
                // Not our orchestrator — prefer native Ollama, then generic OpenAI.
                return await confirmPlainBackend(base: base, token: token)
            }
        } catch {
            let fallback = await confirmPlainBackend(base: base, token: token)
            if case .success = fallback { return fallback }
            return .failure(.from(error))
        }
    }

    /// Discover available model ids for the picker. Uses the orchestrator
    /// manifest when present, otherwise bare `/v1/models`. Empty on failure.
    public func models(base: URL, token: String) async -> [String] {
        (try? await resolve(base: base, token: token).get().models) ?? []
    }

    /// Confirm a bare backend by listing models. Prefer native Ollama when
    /// `/api/tags` is present; otherwise use generic OpenAI `/v1/models`.
    private func confirmPlainBackend(base: URL, token: String) async -> Result<BackendMode, AppError> {
        if let models = await fetchOllamaModelList(base: base, token: token) {
            return .success(.ollamaNative(models: models))
        }

        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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

    /// Probe each native-Ollama model's `/api/show` capabilities concurrently and
    /// return the set that declares `"vision"`. Used to gate image attachments
    /// when talking to a bare Ollama (no orchestrator manifest to consult).
    public func fetchOllamaVisionModels(
        base: URL,
        token: String,
        models: [String]
    ) async -> Set<String> {
        await withTaskGroup(of: String?.self) { group in
            for model in models {
                group.addTask {
                    await self.ollamaModelIsVision(base: base, token: token, model: model)
                        ? model : nil
                }
            }
            var vision: Set<String> = []
            for await result in group {
                if let result { vision.insert(result) }
            }
            return vision
        }
    }

    private func ollamaModelIsVision(base: URL, token: String, model: String) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/show"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let show = try? JSONDecoder().decode(OllamaShowResponse.self, from: data) else {
            return false
        }
        return show.capabilities?.contains("vision") ?? false
    }

    /// Best-effort native Ollama model list. `nil` means `/api/tags` did not
    /// look like Ollama; an empty array still means a native endpoint responded.
    private func fetchOllamaModelList(base: URL, token: String) async -> [String]? {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else {
            return nil
        }
        return tags.models.map(\.name)
    }

    private func decodeModelIDs(_ data: Data) -> [String] {
        (try? JSONDecoder().decode(ModelsResponse.self, from: data))?.data.map(\.id) ?? []
    }

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    private struct OllamaTagsResponse: Decodable {
        struct Entry: Decodable { let name: String }
        let models: [Entry]
    }

    private struct OllamaShowResponse: Decodable {
        let capabilities: [String]?
    }
}
