import Foundation

/// One calendar event returned by the app-hosted calendar tool. Pure value (no
/// EventKit types) so `PhantasmKit` stays host-testable; the app target maps
/// `EKEvent` into this.
public struct CalendarEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarTitle: String
    public var location: String?
    public var notes: String?

    public init(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarTitle: String,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
    }
}

/// What to read from Calendar: a half-open `[start, end)` range plus optional
/// filtering and detail flags. Built by the tool, consumed by the EventKit
/// provider in the app target.
public struct CalendarEventQuery: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var matching: String?
    public var calendarNames: [String]
    public var includeNotes: Bool
    public var maxResults: Int

    public init(
        start: Date,
        end: Date,
        matching: String? = nil,
        calendarNames: [String] = [],
        includeNotes: Bool = false,
        maxResults: Int = CalendarTool.defaultMaxResults
    ) {
        self.start = start
        self.end = end
        self.matching = matching
        self.calendarNames = calendarNames
        self.includeNotes = includeNotes
        self.maxResults = maxResults
    }
}

/// Why a calendar read couldn't run. Each case carries a model-facing sentence
/// folded into the tool result (NFR-O6: never fatal).
public enum CalendarLookupError: Error, Sendable, Equatable {
    case permissionDenied
    case restricted
    case unavailable(String)

    public var modelMessage: String {
        switch self {
        case .permissionDenied:
            return "the user has not granted full Calendar access. Ask them to enable "
                + "Calendar access for Phantasm in Settings, or proceed without their calendar."
        case .restricted:
            return "calendar access is restricted on this device and can't be used."
        case .unavailable(let detail):
            return detail
        }
    }
}

/// Reads the user's calendar. Implemented in the app target with EventKit (which
/// lives there, keeping this package host-testable).
public protocol CalendarProviding: Sendable {
    func events(matching query: CalendarEventQuery) async -> Result<[CalendarEvent], CalendarLookupError>
}

/// The app-hosted `get_calendar_events` tool. It is read-only: creating or
/// editing events would require a separate confirmation flow.
public struct CalendarTool: AutoResolvedTool {
    public static let defaultMaxResults = 20
    static let maxRangeDays = 31
    static let maxAllowedResults = 50

    private let provider: any CalendarProviding

    public init(provider: any CalendarProviding) {
        self.provider = provider
    }

    public let name = ToolName.calendar
    public var statusText: String? { "checking calendar…" }

    public var spec: ToolSpec {
        let deviceZone = TimeZone.current.identifier
        let today = Self.schemaDate(Date(), calendar: .current)
        return ToolSpec(
            name: ToolName.calendar,
            description: "Read the user's on-device Calendar events (read-only). Use it "
                + "whenever a request depends on their schedule, availability, meetings, "
                + "appointments, or upcoming plans. The user's device timezone is "
                + "\"\(deviceZone)\" and today's date is \(today). Pass an explicit "
                + "bounded date range when the user asks about a specific day, week, or "
                + "time window. If no range is given, results default to now through the "
                + "next 7 days. Results include titles, times, calendar names, and "
                + "locations; notes are omitted unless `include_notes` is true. The "
                + "device may prompt for permission the first time; if permission is "
                + "denied the result says so and you should proceed without calendar data.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "start_date": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional range start. Use YYYY-MM-DD for a local day start, "
                                + "or an ISO 8601 date-time for a precise local/offset time."),
                    ]),
                    "end_date": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional exclusive range end. Use YYYY-MM-DD for the start "
                                + "of that local day, or ISO 8601 date-time. The range is "
                                + "capped at 31 days."),
                    ]),
                    "query": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional case-insensitive text filter over event title, "
                                + "location, notes, and calendar name."),
                    ]),
                    "calendars": .object([
                        "type": .string("array"),
                        "description": .string(
                            "Optional calendar-name filters, e.g. Work or Family."),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "include_notes": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Whether to include event notes. Defaults to false; set true "
                                + "only when notes are necessary for the user's request."),
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum number of events to return, 1-50. Defaults to 20."),
                        "minimum": .int(1),
                        "maximum": .int(Self.maxAllowedResults),
                    ]),
                ]),
            ])
        )
    }

    public func resolve(_ call: WireToolCall) async -> String {
        guard let query = Self.parseQuery(call.function?.arguments, now: Date()) else {
            return "get_calendar_events failed: invalid arguments. Pass ISO 8601 "
                + "`start_date`/`end_date` values with a range of 31 days or less."
        }
        switch await provider.events(matching: query) {
        case .success(let events):
            return Self.format(query: query, events: events)
        case .failure(let error):
            return "get_calendar_events failed: \(error.modelMessage)"
        }
    }

    // MARK: - Parsing (pure)

    private struct Args: Decodable {
        let startDate: String?
        let endDate: String?
        let query: String?
        let calendars: [String]?
        let includeNotes: Bool?
        let maxResults: Int?
    }

    /// Parse forwarded arguments into a bounded calendar query. Nil means the
    /// date range is invalid or too wide. Empty/missing JSON falls back to the
    /// default "now through next 7 days" window.
    public static func parseQuery(
        _ raw: String?, now: Date, calendar: Calendar = .current
    ) -> CalendarEventQuery? {
        let args = parseArgs(raw) ?? Args(
            startDate: nil, endDate: nil, query: nil, calendars: nil,
            includeNotes: nil, maxResults: nil
        )
        let start = parseDate(args.startDate, calendar: calendar) ?? now
        let defaultEnd = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let end = parseDate(args.endDate, calendar: calendar) ?? defaultEnd
        guard end > start, isRangeAllowed(start: start, end: end, calendar: calendar) else {
            return nil
        }

        let matching = trimmed(args.query)
        let calendars = (args.calendars ?? []).compactMap(trimmed)
        let maxResults = min(max(args.maxResults ?? defaultMaxResults, 1), maxAllowedResults)
        return CalendarEventQuery(
            start: start,
            end: end,
            matching: matching,
            calendarNames: calendars,
            includeNotes: args.includeNotes ?? false,
            maxResults: maxResults
        )
    }

    private static func parseArgs(_ raw: String?) -> Args? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let data = raw.data(using: .utf8)
        else { return nil }
        return try? Wire.decoder().decode(Args.self, from: data)
    }

    /// Accepts local days (`YYYY-MM-DD`) and ISO 8601 date-times. Date-times with
    /// no offset are interpreted in `calendar.timeZone`.
    private static func parseDate(_ value: String?, calendar: Calendar) -> Date? {
        guard let value = trimmed(value) else { return nil }
        if let day = parseDay(value, calendar: calendar) { return day }
        if let instant = internetDateFormatter.date(from: value) { return instant }
        if let instant = internetDateWithFractionalSecondsFormatter.date(from: value) {
            return instant
        }
        return localDateTimeFormatter(calendar: calendar).date(from: value)
    }

    private static func parseDay(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components).map(calendar.startOfDay(for:))
    }

    private static func isRangeAllowed(start: Date, end: Date, calendar: Calendar) -> Bool {
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? (maxRangeDays + 1)
        return days <= maxRangeDays
    }

    private static var internetDateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static var internetDateWithFractionalSecondsFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func localDateTimeFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }

    // MARK: - Formatting (pure)

    public static func format(
        query: CalendarEventQuery, events: [CalendarEvent], calendar: Calendar = .current
    ) -> String {
        var lines = ["Calendar events (\(rangeLabel(query, calendar: calendar))):"]
        lines.append("count: \(events.count)")
        if events.isEmpty {
            lines.append("No matching events.")
            return lines.joined(separator: "\n")
        }

        for event in events.sorted(by: eventSort) {
            lines.append("- \(eventLine(event, calendar: calendar))")
        }
        return lines.joined(separator: "\n")
    }

    private static func eventLine(_ event: CalendarEvent, calendar: Calendar) -> String {
        var parts = [
            timeLabel(event, calendar: calendar),
            event.calendarTitle,
            trimmed(event.title) ?? "(untitled)",
        ]
        if let location = trimmed(event.location) {
            parts.append("location: \(location)")
        }
        if let notes = trimmed(event.notes) {
            parts.append("notes: \(notes)")
        }
        return parts.joined(separator: " | ")
    }

    private static func timeLabel(_ event: CalendarEvent, calendar: Calendar) -> String {
        if event.isAllDay {
            let start = shortDate(event.start, calendar: calendar)
            let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.start
            let end = shortDate(max(inclusiveEnd, event.start), calendar: calendar)
            return start == end ? "\(start) all day" : "\(start)-\(end) all day"
        }
        let sameDay = calendar.isDate(event.start, inSameDayAs: event.end)
        if sameDay {
            return "\(shortDate(event.start, calendar: calendar)) "
                + "\(shortTime(event.start, calendar: calendar))-"
                + "\(shortTime(event.end, calendar: calendar))"
        }
        return "\(shortDateTime(event.start, calendar: calendar))-"
            + "\(shortDateTime(event.end, calendar: calendar))"
    }

    private static func rangeLabel(_ query: CalendarEventQuery, calendar: Calendar) -> String {
        "\(shortDateTime(query.start, calendar: calendar)) to "
            + "\(shortDateTime(query.end, calendar: calendar))"
    }

    private static func schemaDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func shortTime(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private static func shortDateTime(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }

    private static func eventSort(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
