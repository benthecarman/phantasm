import Foundation
import PhantasmKit

/// Immutable networking and capability state for one backend profile.
///
/// A session is resolved from a conversation's persisted `profileID` and then
/// captured by a turn. Global profile selection may change while the turn is in
/// flight, but its endpoint, credential, transport, and trusted media origin do
/// not.
struct BackendSession: Sendable {
    enum ThinkingSupport {
        case supported
        case unsupported
        case unknown
    }

    let profile: BackendProfile
    let baseURL: URL
    let token: String
    let mode: BackendMode
    let visionModels: Set<String>?
    let toolModels: Set<String>?
    let reasoningEffortsByModel: [String: Capabilities.Model.ReasoningEffortAvailability]?
    let contextLengths: [String: Int]?
    let client: any ChatClienting
    let thinkingPreferences: [String: Bool]
    let reasoningEffortPreferences: [String: String]

    var profileID: UUID { profile.id }
    var trustedMediaBaseURL: URL { baseURL }
    var defaultModelID: String? { profile.defaultModel?.nonEmptyTrimmed }
    var availableModels: [String] { mode.models }
    var preferredModel: String? {
        mode.resolvedChatModel(conversationModel: nil, defaultModel: defaultModelID)
    }

    func resolvedModel(conversationModel: String?) -> String? {
        mode.resolvedChatModel(
            conversationModel: conversationModel,
            defaultModel: defaultModelID
        )
    }

    func supportsVision(_ model: String?) -> Bool {
        guard let visionModels else { return true }
        guard let model else { return false }
        return visionModels.contains(model)
    }

    func supportsTools(_ model: String?) -> Bool {
        guard let toolModels else { return true }
        guard let model else { return false }
        return toolModels.contains(model)
    }

    func supportsThinking(_ model: String?) -> Bool {
        thinkingSupport(for: model) == .supported
    }

    func reasoningEfforts(for model: String?) -> [String] {
        guard let model = model?.nonEmptyTrimmed,
              case .known(let efforts) = reasoningEffortsByModel?[model]
        else { return [] }
        return efforts
    }

    func thinkingSupport(for model: String?) -> ThinkingSupport {
        guard case .full = mode else { return .unsupported }
        guard let model = model?.nonEmptyTrimmed else { return .unknown }
        guard let availability = reasoningEffortsByModel?[model] else { return .unknown }
        switch availability {
        case .unknown:
            return .unknown
        case .known(let efforts):
            return efforts.isEmpty ? .unsupported : .supported
        }
    }

    func thinkingEnabled(for model: String?) -> Bool {
        guard let model = model?.nonEmptyTrimmed,
              supportsThinking(model) else { return false }
        return thinkingPreferences[model] ?? true
    }

    func reasoningEffort(for model: String?) -> String? {
        guard thinkingSupport(for: model) == .supported else { return nil }
        let efforts = reasoningEfforts(for: model)
        guard efforts.count > 2 else {
            return thinkingEnabled(for: model)
                ? preferredEnabledReasoningEffort(from: efforts)
                : disabledReasoningEffort(from: efforts)
        }
        return selectedReasoningEffort(for: model)
    }

    func selectedReasoningEffort(for model: String?) -> String {
        let efforts = reasoningEfforts(for: model)
        guard let model = model?.nonEmptyTrimmed else {
            return preferredEnabledReasoningEffort(from: efforts)
        }
        if let stored = reasoningEffortPreferences[model], efforts.contains(stored) {
            return stored
        }
        return preferredEnabledReasoningEffort(from: efforts)
    }

    private func disabledReasoningEffort(from efforts: [String]) -> String? {
        efforts.first {
            $0.caseInsensitiveCompare(ReasoningEffort.disabled) == .orderedSame
        }
    }

    private func preferredEnabledReasoningEffort(from efforts: [String]) -> String {
        if efforts.contains(ReasoningEffort.enabledDefault) {
            return ReasoningEffort.enabledDefault
        }
        return efforts.first {
            $0.caseInsensitiveCompare(ReasoningEffort.disabled) != .orderedSame
        } ?? ReasoningEffort.enabledDefault
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
