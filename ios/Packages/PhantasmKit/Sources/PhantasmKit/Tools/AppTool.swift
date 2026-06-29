import Foundation

/// The contract every app-hosted tool conforms to. The orchestrator forwards a
/// tool call back to the app (a `delta.tool_calls` chunk); the app looks the tool
/// up in `AppToolRegistry` and handles it according to its kind.
///
/// Two kinds exist, expressed as the two refining protocols below:
///   * `AutoResolvedTool` — the device produces the result itself (possibly async,
///     e.g. reading the clock or asking for location) and the turn continues with
///     no user interaction.
///   * `InteractiveTool` — the app renders UI (an `AppToolPrompt`) and the user's
///     response becomes the result before the turn continues.
///
/// Tools are stateless values so they're trivially `Sendable`. Anything a tool
/// needs from the device (clock, location, …) is passed in or injected, keeping
/// the logic host-testable.
public protocol AppTool: Sendable {
    /// The full function schema advertised to the model (rides in the request's
    /// `tools` array; the orchestrator forwards calls to it back to the app).
    var spec: ToolSpec { get }
    /// The function name the model calls — must match `spec`'s name.
    var name: String { get }
}

/// A tool the device answers itself, with no user interaction. `resolve` may
/// await (permissioned/network device data) and returns the `tool`-role result
/// text. Failures should fold into the returned string (a recoverable result the
/// model can read), never trap.
public protocol AutoResolvedTool: AppTool {
    /// Optional progress line shown while `resolve` runs (e.g. "checking time…").
    var statusText: String? { get }
    func resolve(_ call: WireToolCall) async -> String
}

public extension AutoResolvedTool {
    var statusText: String? { nil }
}

/// A tool the app fulfills by rendering UI and waiting for the user. `prompt(for:)`
/// is a **pure** parse (no side effects) so a forwarded call can be classified
/// and restored after a relaunch without re-executing anything.
public protocol InteractiveTool: AppTool {
    func prompt(for call: WireToolCall) -> AppToolPrompt?
}

/// A piece of UI an `InteractiveTool` asks the app to present. Pure value (lives
/// in `PhantasmKit`); the app maps each case to a SwiftUI view. A new interactive
/// tool adds a case here, a view in the app, and conforms to `InteractiveTool`.
public enum AppToolPrompt: Sendable, Equatable, Identifiable {
    /// The `ask_user_input` multiple-choice form (single/multi/rank questions).
    case multipleChoice(MultipleChoice)
    /// A `create_calendar_event` confirmation. Calendar writes are never
    /// auto-approved; the user must explicitly confirm or cancel.
    case calendarEvent(CalendarEventConfirmation)

    /// The forwarded call this prompt answers — its result rides this id.
    public var toolCallId: String {
        switch self {
        case .multipleChoice(let choice): return choice.toolCallId
        case .calendarEvent(let confirmation): return confirmation.toolCallId
        }
    }

    /// The tool name recorded on the `tool`-role result row.
    public var toolName: String {
        switch self {
        case .multipleChoice: return ToolName.askUser
        case .calendarEvent: return ToolName.createCalendarEvent
        }
    }

    public var id: String { toolCallId }

    public var acceptsFreeTextAnswer: Bool {
        switch self {
        case .multipleChoice: return true
        case .calendarEvent: return false
        }
    }
}

/// `ask_user_input`: an interactive multiple-choice prompt. A single tool that
/// owns all three question types (single/multi/rank) via its `questions` array —
/// the type is a parameter, not a separate tool. Parsing lives in `AskUserParser`.
public struct AskUserTool: InteractiveTool {
    public init() {}
    public let name = ToolName.askUser

    public func prompt(for call: WireToolCall) -> AppToolPrompt? {
        AskUserParser.parse(call).map(AppToolPrompt.multipleChoice)
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: ToolName.askUser,
            description: "Present tappable multiple-choice options to gather the user's "
                + "preferences, constraints, or goals before advising — tapping beats "
                + "typing on mobile. Use it for ELICITATION: open-ended requests where "
                + "the right answer depends on facts only the user has (e.g. \"plan a "
                + "workout\" -> ask goals, time, equipment).\n\n"
                + "First check the conversation: if the answer is already stated or "
                + "inferable, don't ask — proceed and state your assumption.\n\n"
                + "Do NOT use when the user poses an A-or-B choice (they want your "
                + "recommendation), is venting, asks your opinion, asks a plain factual "
                + "question, wants prose feedback (e.g. \"review my code\"), or already "
                + "gave a detailed constrained prompt.\n\n"
                + "Add a short lead-in before the options. One question is best, three "
                + "max; each with 2-4 short, mutually-exclusive options. After calling, "
                + "your turn ends — the user's pick arrives as their next message, so "
                + "don't keep writing.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "questions": .object([
                        "type": .string("array"),
                        "description": .string("1-3 questions to ask the user."),
                        "minItems": .int(1),
                        "maxItems": .int(3),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "question": .object([
                                    "type": .string("string"),
                                    "description": .string("The question text shown to the user."),
                                ]),
                                "options": .object([
                                    "type": .string("array"),
                                    "description": .string(
                                        "2-4 short, mutually exclusive option labels."),
                                    "minItems": .int(2),
                                    "maxItems": .int(4),
                                    "items": .object(["type": .string("string")]),
                                ]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string("single_select"),
                                        .string("multi_select"),
                                        .string("rank_priorities"),
                                    ]),
                                    "default": .string("single_select"),
                                    "description": .string(
                                        "Question type: 'single_select' to choose one "
                                            + "option, 'multi_select' to choose one or more, "
                                            + "'rank_priorities' for drag-and-drop ranking."),
                                ]),
                            ]),
                            "required": .array([.string("question"), .string("options")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("questions")]),
            ])
        )
    }
}

/// The single source of truth for the app's hosted tools. The request layer reads
/// `specs` (what to advertise); the view model reads `match`/`firstUnansweredPrompt`
/// to route forwarded calls. Adding a tool is one entry here.
public enum AppToolRegistry {
    /// The always-available, dependency-free hosted tools. `ask_user` is first so a
    /// forwarded interactive prompt is preferred when a batch mixes it with
    /// auto-resolved calls.
    private static let baseTools: [any AppTool] = [
        AskUserTool(), CurrentTimeTool(), RenderChartTool(),
    ]

    /// The device-backed tools (location, health, calendar), wired in at app launch with
    /// their providers. Guarded by a lock so the (non-isolated) accessors below
    /// stay usable from host tests, which simply never configure them — the tool
    /// is then neither advertised nor routed. CoreLocation/HealthKit/EventKit live
    /// in the app target, so they can't be constructed here.
    private static let lock = NSLock()
    private static var configuredLocationTool: LocationTool?
    private static var configuredHealthTool: HealthTool?
    private static var configuredCalendarTool: CalendarTool?
    private static var configuredCalendarCreateEventTool: CalendarCreateEventTool?

    /// Wire the device-backed location tool into the registry. Call once at app
    /// launch (idempotent — replaces any prior provider).
    public static func configureLocation(provider: any LocationProviding) {
        lock.lock()
        defer { lock.unlock() }
        configuredLocationTool = LocationTool(provider: provider)
    }

    /// Wire the device-backed health tool into the registry. Call once at app
    /// launch (idempotent — replaces any prior provider).
    public static func configureHealth(provider: any HealthProviding) {
        lock.lock()
        defer { lock.unlock() }
        configuredHealthTool = HealthTool(provider: provider)
    }

    /// Wire the device-backed calendar tool into the registry. Call once at app
    /// launch (idempotent — replaces any prior provider).
    public static func configureCalendar(provider: any CalendarProviding) {
        lock.lock()
        defer { lock.unlock() }
        configuredCalendarTool = CalendarTool(provider: provider)
        configuredCalendarCreateEventTool = CalendarCreateEventTool(provider: provider)
    }

    private static var locationTool: LocationTool? {
        lock.lock()
        defer { lock.unlock() }
        return configuredLocationTool
    }

    private static var healthTool: HealthTool? {
        lock.lock()
        defer { lock.unlock() }
        return configuredHealthTool
    }

    private static var calendarTool: CalendarTool? {
        lock.lock()
        defer { lock.unlock() }
        return configuredCalendarTool
    }

    private static var calendarCreateEventTool: CalendarCreateEventTool? {
        lock.lock()
        defer { lock.unlock() }
        return configuredCalendarCreateEventTool
    }

    /// Every hosted tool currently available (device-backed tools only once
    /// their providers are configured at launch).
    public static var tools: [any AppTool] {
        var out = baseTools
        if let locationTool { out.append(locationTool) }
        if let healthTool { out.append(healthTool) }
        if let calendarTool { out.append(calendarTool) }
        if let calendarCreateEventTool { out.append(calendarCreateEventTool) }
        return out
    }

    /// Schemas to advertise this turn (the `tools` array).
    public static var specs: [ToolSpec] { tools.map(\.spec) }

    private static func tool(named name: String) -> (any AppTool)? {
        tools.first { $0.name == name }
    }

    /// How a forwarded call should be handled.
    public enum Match {
        case auto(any AutoResolvedTool)
        case interactive(any InteractiveTool)
        /// No hosted tool by that name (shouldn't happen — we only advertise ours).
        case unknown
    }

    public static func match(_ call: WireToolCall) -> Match {
        guard let name = call.function?.name, let tool = tool(named: name) else { return .unknown }
        if let auto = tool as? any AutoResolvedTool { return .auto(auto) }
        if let interactive = tool as? any InteractiveTool { return .interactive(interactive) }
        return .unknown
    }

    /// Whether a `tool`-role result row came from an auto-resolved tool — used to
    /// keep its (model-facing, non-prose) output out of the transcript.
    public static func isAutoResolved(name: String?) -> Bool {
        guard let name, let tool = tool(named: name) else { return false }
        return tool is any AutoResolvedTool
    }

    public static func createCalendarEvent(_ confirmation: CalendarEventConfirmation) async -> String {
        guard let tool = calendarCreateEventTool else {
            return "create_calendar_event failed: calendar event creation is not configured."
        }
        return await tool.create(confirmation)
    }

    /// The first interactive prompt among `calls` that has no result yet (used to
    /// restore a pending prompt after a relaunch, including a mixed batch whose
    /// auto results were already persisted). Nil if none remain.
    public static func firstUnansweredPrompt(
        calls: [WireToolCall], answered: Set<String>
    ) -> AppToolPrompt? {
        for call in calls {
            if let id = call.id, answered.contains(id) { continue }
            if case .interactive(let tool) = match(call), let prompt = tool.prompt(for: call) {
                return prompt
            }
        }
        return nil
    }
}
