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

    public struct OllamaModelCapabilities: Sendable, Equatable {
        public let visionModels: Set<String>
        /// `nil` when any probe failed, preserving the app's optimistic
        /// compatibility behavior instead of falsely hiding tools.
        public let toolModels: Set<String>?
        public let contextLengths: [String: Int]
    }

    /// Probe native-Ollama `/api/show` metadata in bounded batches. Alongside
    /// vision this discovers tool calling and context lengths, while avoiding a
    /// connection burst on hosts with a large model library.
    public func fetchOllamaModelCapabilities(
        base: URL,
        token: String,
        models: [String],
        maxConcurrency: Int = 6
    ) async -> OllamaModelCapabilities {
        var vision: Set<String> = []
        var tools: Set<String> = []
        var contextLengths: [String: Int] = [:]
        var allSucceeded = true
        let width = max(1, maxConcurrency)

        for start in stride(from: 0, to: models.count, by: width) {
            let end = min(models.count, start + width)
            let batch = Array(models[start..<end])
            await withTaskGroup(of: (String, OllamaShowMetadata?).self) { group in
                for model in batch {
                    group.addTask {
                        (model, await self.ollamaModelMetadata(
                            base: base, token: token, model: model
                        ))
                    }
                }
                for await (model, metadata) in group {
                    guard let metadata else {
                        allSucceeded = false
                        continue
                    }
                    if metadata.capabilities.contains("vision") { vision.insert(model) }
                    if metadata.capabilities.contains("tools") { tools.insert(model) }
                    if let contextLength = metadata.contextLength {
                        contextLengths[model] = contextLength
                    }
                }
            }
        }
        return .init(
            visionModels: vision,
            toolModels: allSucceeded ? tools : nil,
            contextLengths: contextLengths
        )
    }

    /// Backward-compatible vision-only facade retained for existing callers.
    public func fetchOllamaVisionModels(
        base: URL,
        token: String,
        models: [String]
    ) async -> Set<String> {
        await fetchOllamaModelCapabilities(base: base, token: token, models: models)
            .visionModels
    }

    private func ollamaModelMetadata(
        base: URL, token: String, model: String
    ) async -> OllamaShowMetadata? {
        var req = URLRequest(url: base.appendingPathComponent("api/show"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any]
        else { return nil }
        let capabilities = Set(object["capabilities"] as? [String] ?? [])
        let info = object["model_info"] as? [String: Any] ?? [:]
        let contextLength = info
            .first { $0.key.hasSuffix(".context_length") }
            .flatMap { ($0.value as? NSNumber)?.intValue }
            .flatMap { $0 > 0 ? $0 : nil }
        return .init(capabilities: capabilities, contextLength: contextLength)
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

    private struct OllamaShowMetadata: Sendable {
        let capabilities: Set<String>
        let contextLength: Int?
    }
}

/// Resolves the same backend surface as `CapabilitiesClient`, with one
/// additional fallback: when ordinary Phantasm/Ollama/OpenAI probing fails,
/// try the OpenSecret encrypted transport. A successful Maple probe is marked
/// in `BackendMode` so chat can use `MapleChatClient`; the model list and all
/// subsequent chat semantics remain ordinary OpenAI-compatible behavior.
public struct BackendResolver: Sendable {
    private let standard: CapabilitiesClient
    private let maple: CapabilitiesClient

    public init(
        session: URLSession = .shared,
        mapleSession: URLSession? = nil
    ) {
        self.standard = CapabilitiesClient(session: session)
        self.maple = CapabilitiesClient(
            session: mapleSession ?? MapleEncryptedTransport.session()
        )
    }

    public func resolve(
        base: URL,
        token: String,
        preferMaple: Bool = false
    ) async -> Result<BackendMode, AppError> {
        if preferMaple, let encrypted = await resolveMaple(base: base, token: token) {
            return encrypted
        }

        let ordinary = await standard.resolve(base: base, token: token)
        if case .success = ordinary { return ordinary }

        return await resolveMaple(base: base, token: token) ?? ordinary
    }

    private func resolveMaple(
        base: URL,
        token: String
    ) async -> Result<BackendMode, AppError>? {
        // The attestation/key-exchange endpoints are the positive Maple signal.
        // A random unreachable or non-Maple OpenAI host keeps its original error
        // instead of being relabeled as an encrypted backend failure.
        do {
            try await MapleEncryptedTransport.prepare(base: base)
        } catch {
            return nil
        }

        switch await maple.resolve(base: base, token: token) {
        case .success(let mode):
            return .success(.mapleEncrypted(models: mode.models))
        case .failure(let error):
            return .failure(error)
        }
    }

    public func models(
        base: URL,
        token: String,
        preferMaple: Bool = false
    ) async -> [String] {
        (try? await resolve(
            base: base, token: token, preferMaple: preferMaple
        ).get().models) ?? []
    }
}
