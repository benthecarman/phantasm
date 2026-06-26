import Foundation

/// A multiple-choice prompt parsed from an `ask_user` tool call (the app-hosted
/// tool, see `AppTools.askUser`). Carries one or more questions answered together
/// in a single form. Pure value type so the parser is host-testable.
public struct MultipleChoice: Sendable, Equatable, Identifiable {
    /// How the user answers a question.
    public enum QuestionType: String, Sendable, Equatable {
        /// Pick exactly one option.
        case singleSelect = "single_select"
        /// Pick any number of options.
        case multiSelect = "multi_select"
        /// Order the options from most to least important.
        case rankPriorities = "rank_priorities"
    }

    /// One question within the form: its prompt, candidate answers, and how the
    /// user answers it.
    public struct Question: Sendable, Equatable {
        public let prompt: String
        public let options: [String]
        public let type: QuestionType

        public init(prompt: String, options: [String], type: QuestionType) {
            self.prompt = prompt
            self.options = options
            self.type = type
        }
    }

    /// The forwarded tool call's id — the answer is returned as a `tool`-role
    /// message carrying this id.
    public let toolCallId: String
    public let questions: [Question]

    public var id: String { toolCallId }

    public init(toolCallId: String, questions: [Question]) {
        self.toolCallId = toolCallId
        self.questions = questions
    }
}

/// Parses `ask_user` tool calls into a `MultipleChoice`. Tolerant: a call that
/// isn't `ask_user`, has unparseable arguments, or yields no usable question
/// (each needs a prompt and ≥2 options) returns nil — the UI then falls back to
/// free-typing only. Accepts both the `{questions:[…]}` form and a legacy single
/// `{question, options}` form, since small models emit either.
public enum AskUserParser {
    private struct QuestionArg: Decodable {
        let question: String
        let options: [String]
        let type: String?
        let allowMultiple: Bool?
    }

    private struct MultiArguments: Decodable {
        let questions: [QuestionArg]
    }

    /// Parse a single tool call, or nil if it isn't a usable `ask_user` prompt.
    public static func parse(_ call: WireToolCall) -> MultipleChoice? {
        guard call.function?.name == ToolName.askUser,
              let id = call.id, !id.isEmpty,
              let raw = call.function?.arguments,
              let data = raw.data(using: .utf8)
        else { return nil }

        let decoder = Wire.decoder()
        let rawQuestions: [QuestionArg]
        if let multi = try? decoder.decode(MultiArguments.self, from: data) {
            rawQuestions = multi.questions
        } else if let single = try? decoder.decode(QuestionArg.self, from: data) {
            rawQuestions = [single]
        } else {
            return nil
        }

        let questions = rawQuestions.compactMap(clean)
        guard !questions.isEmpty else { return nil }
        return MultipleChoice(toolCallId: id, questions: questions)
    }

    /// Trim and validate one raw question; nil if it lacks a prompt or ≥2 options.
    private static func clean(_ arg: QuestionArg) -> MultipleChoice.Question? {
        let prompt = arg.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = arg.options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !prompt.isEmpty, options.count >= 2 else { return nil }
        return .init(prompt: prompt, options: options, type: resolveType(arg))
    }

    /// Prefer the explicit `type`; fall back to the legacy `allow_multiple`
    /// boolean; default to single-select for anything unrecognized.
    private static func resolveType(_ arg: QuestionArg) -> MultipleChoice.QuestionType {
        if let raw = arg.type?.trimmingCharacters(in: .whitespacesAndNewlines),
           let type = MultipleChoice.QuestionType(rawValue: raw) {
            return type
        }
        return (arg.allowMultiple == true) ? .multiSelect : .singleSelect
    }

    /// The first usable `ask_user` prompt among forwarded calls, if any.
    public static func firstChoice(in calls: [WireToolCall]) -> MultipleChoice? {
        calls.lazy.compactMap(parse).first
    }
}
