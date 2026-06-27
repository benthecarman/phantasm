import Foundation

/// The app-hosted `current_time` tool. Unlike `ask_user_input`, this one needs no
/// UI: the device already knows its own clock and timezone, so the app answers the
/// forwarded call itself (an `AutoResolvedTool`) and the turn continues
/// automatically. The formatting is pure/static so it's host-testable via
/// `swift test`.
///
/// Output mirrors the format the orchestrator's old server-side tool produced, so
/// the model sees a familiar block — except the default zone is now the user's
/// **device** timezone (the whole point of hosting it on the device) rather than
/// UTC.
public struct CurrentTimeTool: AutoResolvedTool {
    public init() {}
    public let name = ToolName.currentTime
    public var statusText: String? { "checking time…" }

    public var spec: ToolSpec {
        // Carry the device's live timezone in the schema each turn, so the model
        // knows where the user is — useful for time reasoning ("3pm my time")
        // even before deciding to call the tool. The list is rebuilt per request,
        // so this tracks the device if the user travels / changes zones.
        let deviceZone = TimeZone.current.identifier
        return ToolSpec(
            name: ToolName.currentTime,
            description: "Get the current date and time. The user's device timezone "
                + "is \"\(deviceZone)\" and results default to it; pass `timezone` only "
                + "to ask about a different zone (an IANA name like \"America/Chicago\" "
                + "or \"UTC\", or a fixed UTC offset like \"-05:00\"). Use it whenever "
                + "the current date, time, day of week, or timezone is needed.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "timezone": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional. IANA timezone like \"America/Chicago\" or \"UTC\", "
                                + "or a fixed offset like \"-05:00\". Omit to use the "
                                + "user's device timezone (\"\(deviceZone)\")."),
                    ]),
                ]),
            ])
        )
    }

    /// Resolve a forwarded call against the live device clock. Folds a malformed
    /// call into a recoverable error string rather than failing the turn.
    public func resolve(_ call: WireToolCall) async -> String {
        Self.resolve(call, now: Date()) ?? "current_time failed: invalid arguments"
    }

    /// Whether any forwarded call is a `current_time` call this tool can answer.
    public static func handles(_ calls: [WireToolCall]) -> Bool {
        calls.contains { $0.function?.name == ToolName.currentTime }
    }

    /// The `tool`-role result text for one forwarded `current_time` call, or nil
    /// if the call isn't `current_time`. An unknown requested timezone yields an
    /// error string (still a valid result the model can recover from), never nil.
    public static func resolve(_ call: WireToolCall, now: Date) -> String? {
        guard call.function?.name == ToolName.currentTime else { return nil }
        return format(now: now, requested: parseTimezoneArg(call.function?.arguments))
    }

    private struct Args: Decodable { let timezone: String? }

    private static func parseTimezoneArg(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let args = try? Wire.decoder().decode(Args.self, from: data)
        else { return nil }
        return args.timezone
    }

    /// Format the answer block for `now` in the requested zone. `requested` nil or
    /// empty → the device's own timezone.
    static func format(now: Date, requested: String?) -> String {
        let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let utcLine = iso8601(now, timeZone: utc)
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines)

        // No timezone requested → answer in the device's own zone.
        guard let trimmed, !trimmed.isEmpty else {
            let tz = TimeZone.current
            let isUTC = tz.secondsFromGMT(for: now) == 0
            return block(label: tz.identifier, now: now, tz: tz, utc: utcLine, includeUTC: !isUTC)
        }

        if trimmed.caseInsensitiveCompare("UTC") == .orderedSame {
            return block(label: "UTC", now: now, tz: utc, utc: utcLine, includeUTC: false)
        }
        if let tz = TimeZone(identifier: trimmed) {
            return block(label: trimmed, now: now, tz: tz, utc: utcLine, includeUTC: true)
        }
        if let (tz, label) = parseOffset(trimmed) {
            return block(label: label, now: now, tz: tz, utc: utcLine, includeUTC: true)
        }
        return "current_time failed: unknown timezone `\(trimmed)`; use UTC, an IANA "
            + "timezone like America/Chicago, or an offset like -05:00"
    }

    private static func block(
        label: String, now: Date, tz: TimeZone, utc: String, includeUTC: Bool
    ) -> String {
        var lines = [
            "Current time:",
            "timezone: \(label)",
            "clock: \(clock12h(now, tz: tz))",
            "iso8601: \(iso8601(now, timeZone: tz))",
        ]
        if includeUTC { lines.append("utc: \(utc)") }
        return lines.joined(separator: "\n")
    }

    /// Human-readable 12-hour clock, e.g. "Friday, June 26, 2026 at 3:07:42 PM".
    private static func clock12h(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        return f.string(from: date)
    }

    /// RFC3339 / ISO8601 with second precision, e.g. "2026-06-26T15:07:42-05:00"
    /// (or "…Z" for UTC).
    private static func iso8601(_ date: Date, timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// Parse a fixed UTC offset like "+14:00" / "-05:00" into a zone and a "UTC±…"
    /// label. Requires a leading sign and `HH:MM`; nil for anything else.
    private static func parseOffset(_ raw: String) -> (TimeZone, String)? {
        guard let first = raw.first, first == "+" || first == "-" else { return nil }
        let sign = first == "+" ? 1 : -1
        let parts = raw.dropFirst().split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...23).contains(hours), (0...59).contains(minutes),
              let tz = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
        else { return nil }
        return (tz, "UTC\(raw)")
    }
}
