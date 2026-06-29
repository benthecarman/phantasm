import Foundation

/// A health metric the model can request. A pure value (no HealthKit types) so
/// `PhantasmKit` stays host-testable — the app maps each case to its
/// `HKObjectType`, unit, and aggregation in `HealthKitProvider`.
public enum HealthMetric: String, Sendable, CaseIterable, Equatable {
    // Activity — summed over the range.
    case steps
    case walkingRunningDistance = "walking_running_distance"
    case activeEnergy = "active_energy"
    case exerciseMinutes = "exercise_minutes"
    // Vitals — averaged, with min/max.
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "heart_rate_variability"
    case respiratoryRate = "respiratory_rate"
    case bloodOxygen = "blood_oxygen"
    // Body — most recent value.
    case weight
    case height
    case bodyMassIndex = "bmi"
    case bodyFat = "body_fat"
    // Special shapes.
    case sleep
    case workouts

    /// How this metric aggregates over a range — drives both the provider's
    /// query (sum vs. average vs. most-recent) and the formatter's line shape.
    public enum Kind: Sendable, Equatable {
        /// Totalled across the range (steps, energy, distance, exercise minutes).
        case cumulative
        /// Averaged across samples, reported with min/max (heart rate, SpO₂, …).
        case discrete
        /// Only the latest sample matters (weight, height, BMI, body fat).
        case latest
        /// Sleep stages, summed by stage.
        case sleep
        /// A list of recent workouts.
        case workouts
    }

    public var kind: Kind {
        switch self {
        case .steps, .walkingRunningDistance, .activeEnergy, .exerciseMinutes:
            return .cumulative
        case .heartRate, .restingHeartRate, .heartRateVariability, .respiratoryRate, .bloodOxygen:
            return .discrete
        case .weight, .height, .bodyMassIndex, .bodyFat:
            return .latest
        case .sleep:
            return .sleep
        case .workouts:
            return .workouts
        }
    }
}

/// Why a health read couldn't run at all (as opposed to an individual metric
/// having no data, which is a per-metric `HealthReading`). Each case carries a
/// model-facing sentence folded into the tool result (NFR-O6: never fatal).
public enum HealthLookupError: Error, Sendable, Equatable {
    /// HealthKit isn't available on this device (e.g. iPad without Health).
    case unavailable
    /// Requesting authorization threw, with detail.
    case authorizationFailed(String)

    /// The sentence shown to the model so it can recover (ask the user, or
    /// proceed without health data).
    public var modelMessage: String {
        switch self {
        case .unavailable:
            return "Health data isn't available on this device."
        case .authorizationFailed(let detail):
            return detail
        }
    }
}

/// What to read: the metrics and the (half-open) time range `[start, end)`.
/// Built by the tool from the model's arguments; consumed by the provider.
public struct HealthQuery: Sendable, Equatable {
    public var metrics: [HealthMetric]
    public var start: Date
    public var end: Date

    public init(metrics: [HealthMetric], start: Date, end: Date) {
        self.metrics = metrics
        self.start = start
        self.end = end
    }
}

/// An aggregated numeric reading for a quantity metric. Which fields are
/// populated depends on the metric's `kind` (sum for cumulative, average/min/max
/// for discrete, latest for body metrics). `unit` is a short, model-readable
/// label like "bpm", "kg", or "kcal".
public struct HealthSummary: Sendable, Equatable {
    public var unit: String
    public var sum: Double?
    public var average: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var latest: Double?
    public var latestDate: Date?

    public init(
        unit: String,
        sum: Double? = nil,
        average: Double? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        latest: Double? = nil,
        latestDate: Date? = nil
    ) {
        self.unit = unit
        self.sum = sum
        self.average = average
        self.minimum = minimum
        self.maximum = maximum
        self.latest = latest
        self.latestDate = latestDate
    }
}

/// Sleep durations summed over the range, in seconds. Any field may be nil when
/// the source didn't record that stage.
public struct HealthSleepSummary: Sendable, Equatable {
    public var asleep: TimeInterval?
    public var inBed: TimeInterval?
    public var deep: TimeInterval?
    public var rem: TimeInterval?
    public var core: TimeInterval?
    public var awake: TimeInterval?

    public init(
        asleep: TimeInterval? = nil,
        inBed: TimeInterval? = nil,
        deep: TimeInterval? = nil,
        rem: TimeInterval? = nil,
        core: TimeInterval? = nil,
        awake: TimeInterval? = nil
    ) {
        self.asleep = asleep
        self.inBed = inBed
        self.deep = deep
        self.rem = rem
        self.core = core
        self.awake = awake
    }
}

/// One workout in the range. Distance/energy are optional (not every workout
/// records them).
public struct HealthWorkout: Sendable, Equatable {
    public var activity: String
    public var start: Date
    public var duration: TimeInterval
    public var energyKcal: Double?
    public var distanceMeters: Double?

    public init(
        activity: String,
        start: Date,
        duration: TimeInterval,
        energyKcal: Double? = nil,
        distanceMeters: Double? = nil
    ) {
        self.activity = activity
        self.start = start
        self.duration = duration
        self.energyKcal = energyKcal
        self.distanceMeters = distanceMeters
    }
}

/// The resolved reading for one metric. `noData` means authorized-but-empty *or*
/// read access wasn't granted — HealthKit deliberately hides read-denial, so the
/// two are indistinguishable (the tool description tells the model as much).
public enum HealthReading: Sendable, Equatable {
    case quantity(HealthSummary)
    case sleep(HealthSleepSummary)
    case workouts([HealthWorkout])
    case noData
    case unavailable(String)
}

/// One metric paired with its reading, as returned by the provider.
public struct HealthMetricResult: Sendable, Equatable {
    public var metric: HealthMetric
    public var reading: HealthReading

    public init(metric: HealthMetric, reading: HealthReading) {
        self.metric = metric
        self.reading = reading
    }
}

/// Reads on-device health data. Implemented in the app target with HealthKit
/// (which lives there, keeping this package host-testable); the tool holds an
/// injected provider so its parsing/formatting stay pure.
public protocol HealthProviding: Sendable {
    func read(_ query: HealthQuery) async -> Result<[HealthMetricResult], HealthLookupError>
}

/// The app-hosted `get_health_data` tool. Like `get_current_location` it needs no
/// UI — the device answers the forwarded call itself (an `AutoResolvedTool`) and
/// the turn continues. The actual data comes from an injected `HealthProviding`
/// (HealthKit, app side); the arg parsing and result formatting are pure/static
/// so they're host-testable. Read-only: writing health data would be a
/// side-effecting tool requiring a separate confirmation flow (SPEC §2.3).
public struct HealthTool: AutoResolvedTool {
    private let provider: any HealthProviding

    public init(provider: any HealthProviding) {
        self.provider = provider
    }

    public let name = ToolName.health
    public var statusText: String? { "reading health data…" }

    public var spec: ToolSpec {
        let metricValues = HealthMetric.allCases.map { JSONValue.string($0.rawValue) }
        return ToolSpec(
            name: ToolName.health,
            description: "Read the user's on-device Apple Health data (read-only). Use it "
                + "whenever a request depends on the user's health or fitness — steps, "
                + "workouts, heart rate, sleep, weight, etc. Returns aggregated summaries "
                + "over a time range: totals for activity (steps, distance, energy, "
                + "exercise minutes), averages with min/max for vitals (heart rate, resting "
                + "heart rate, HRV, respiratory rate, blood oxygen), the latest value for "
                + "body metrics (weight, height, BMI, body fat), sleep stage durations, and "
                + "recent workouts. Times use the device's local days. The device may prompt "
                + "for permission the first time; a metric that returns \"no data\" may mean "
                + "the user has nothing recorded OR hasn't granted access to it — if you need "
                + "it, ask them to enable it for Phantasm in Settings > Health. Default range "
                + "is today when none is given.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "metrics": .object([
                        "type": .string("array"),
                        "description": .string(
                            "Which health metrics to read. Pick only what's needed."),
                        "minItems": .int(1),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array(metricValues),
                        ]),
                    ]),
                    "period": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("today"), .string("yesterday"),
                            .string("last_7_days"), .string("last_30_days"),
                            .string("last_90_days"), .string("this_week"),
                            .string("this_month"),
                        ]),
                        "description": .string(
                            "Convenience time range. Omit to use today, or override with "
                                + "start_date/end_date."),
                    ]),
                    "start_date": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Start of the range as an ISO date \"YYYY-MM-DD\" (device-local "
                                + "day, inclusive). Overrides `period` when given."),
                    ]),
                    "end_date": .object([
                        "type": .string("string"),
                        "description": .string(
                            "End of the range as an ISO date \"YYYY-MM-DD\" (device-local "
                                + "day, inclusive). Defaults to today when only start_date is "
                                + "given."),
                    ]),
                ]),
                "required": .array([.string("metrics")]),
            ])
        )
    }

    public func resolve(_ call: WireToolCall) async -> String {
        guard let query = Self.parseQuery(call.function?.arguments, now: Date()) else {
            return "get_health_data failed: no valid metrics requested. Provide a non-empty "
                + "`metrics` array using the supported metric names."
        }
        switch await provider.read(query) {
        case .success(let results):
            return Self.format(query: query, results: results)
        case .failure(let error):
            return "get_health_data failed: \(error.modelMessage)"
        }
    }

    // MARK: - Parsing (pure)

    private struct Args: Decodable {
        let metrics: [String]?
        let period: String?
        let start_date: String?
        let end_date: String?
    }

    /// Parse forwarded arguments into a `HealthQuery`. Returns nil when no valid
    /// metric is requested (the only hard failure; an unknown range falls back to
    /// today). `calendar` is injectable so range math is deterministic in tests.
    public static func parseQuery(
        _ raw: String?, now: Date, calendar: Calendar = .current
    ) -> HealthQuery? {
        guard let raw, let data = raw.data(using: .utf8),
              let args = try? Wire.decoder().decode(Args.self, from: data)
        else { return nil }

        let metrics = (args.metrics ?? []).compactMap(HealthMetric.init(rawValue:))
        guard !metrics.isEmpty else { return nil }

        let range = dateRange(
            period: args.period, startDate: args.start_date, endDate: args.end_date,
            now: now, calendar: calendar
        )
        return HealthQuery(metrics: metrics, start: range.start, end: range.end)
    }

    /// Resolve the half-open `[start, end)` range. Explicit start/end win over
    /// `period`; everything falls back to "today". `end` is the start of the day
    /// *after* the inclusive last day.
    static func dateRange(
        period: String?, startDate: String?, endDate: String?, now: Date, calendar: Calendar
    ) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        if let start = parseDay(startDate, calendar: calendar) {
            let lastDay = parseDay(endDate, calendar: calendar) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: max(lastDay, start)) ?? tomorrow
            return (start, end)
        }

        func daysAgo(_ n: Int) -> Date {
            calendar.date(byAdding: .day, value: -n, to: today) ?? today
        }
        switch period {
        case "yesterday":
            return (daysAgo(1), today)
        case "last_7_days":
            return (daysAgo(6), tomorrow)
        case "last_30_days":
            return (daysAgo(29), tomorrow)
        case "last_90_days":
            return (daysAgo(89), tomorrow)
        case "this_week":
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            return (start, tomorrow)
        case "this_month":
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? today
            return (start, tomorrow)
        default: // "today", nil, or anything unrecognized
            return (today, tomorrow)
        }
    }

    /// Parse a "YYYY-MM-DD" day into the start of that day in `calendar`'s zone.
    private static func parseDay(_ value: String?, calendar: Calendar) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components).map(calendar.startOfDay(for:))
    }

    // MARK: - Formatting (pure)

    /// Render the answer block (pure, host-testable). One `metric: value` line per
    /// result, mirroring `current_time` / `get_current_location`'s shape.
    public static func format(
        query: HealthQuery, results: [HealthMetricResult], calendar: Calendar = .current
    ) -> String {
        var lines = ["Health data (\(rangeLabel(query, calendar: calendar))):"]
        for result in results {
            lines.append("\(result.metric.rawValue): \(line(for: result, query: query, calendar: calendar))")
        }
        if results.isEmpty {
            lines.append("(no metrics returned)")
        }
        return lines.joined(separator: "\n")
    }

    private static func line(
        for result: HealthMetricResult, query: HealthQuery, calendar: Calendar
    ) -> String {
        switch result.reading {
        case .quantity(let summary):
            return quantityLine(result.metric, summary, query: query, calendar: calendar)
        case .sleep(let sleep):
            return sleepLine(sleep)
        case .workouts(let workouts):
            return workoutsLine(workouts, calendar: calendar)
        case .noData:
            return "no data in range"
        case .unavailable(let detail):
            return detail
        }
    }

    private static func quantityLine(
        _ metric: HealthMetric, _ summary: HealthSummary, query: HealthQuery, calendar: Calendar
    ) -> String {
        let unit = summary.unit
        switch metric.kind {
        case .cumulative:
            guard let sum = summary.sum else { return "no data in range" }
            var text = "\(number(sum)) \(unit) total"
            let days = dayCount(query, calendar: calendar)
            if days > 1 {
                text += " (avg \(number(sum / Double(days)))/day)"
            }
            return text
        case .discrete:
            guard let average = summary.average else { return "no data in range" }
            var text = "avg \(number(average)) \(unit)"
            if let lo = summary.minimum, let hi = summary.maximum {
                text += " (min \(number(lo)), max \(number(hi)))"
            }
            return text
        case .latest:
            guard let latest = summary.latest else { return "no data in range" }
            var text = "\(number(latest)) \(unit)"
            if let date = summary.latestDate {
                text += " (as of \(shortDate(date, calendar: calendar)))"
            }
            return text
        case .sleep, .workouts:
            return "no data in range"
        }
    }

    private static func sleepLine(_ sleep: HealthSleepSummary) -> String {
        guard sleep.asleep != nil || sleep.inBed != nil else { return "no data in range" }
        var parts: [String] = []
        if let asleep = sleep.asleep { parts.append("\(duration(asleep)) asleep") }
        if let inBed = sleep.inBed { parts.append("\(duration(inBed)) in bed") }
        var stages: [String] = []
        if let deep = sleep.deep { stages.append("deep \(duration(deep))") }
        if let rem = sleep.rem { stages.append("REM \(duration(rem))") }
        if let core = sleep.core { stages.append("core \(duration(core))") }
        if let awake = sleep.awake { stages.append("awake \(duration(awake))") }
        var text = parts.joined(separator: ", ")
        if !stages.isEmpty { text += " [\(stages.joined(separator: ", "))]" }
        return text
    }

    private static func workoutsLine(_ workouts: [HealthWorkout], calendar: Calendar) -> String {
        guard !workouts.isEmpty else { return "no data in range" }
        let items = workouts.map { workout -> String in
            var text = "\(workout.activity) \(duration(workout.duration))"
            if let energy = workout.energyKcal { text += " \(number(energy)) kcal" }
            if let distance = workout.distanceMeters {
                text += " \(number(distance / 1000)) km"
            }
            text += " (\(shortDate(workout.start, calendar: calendar)))"
            return text
        }
        return "\(workouts.count) — \(items.joined(separator: "; "))"
    }

    // MARK: - Range helpers

    private static func dayCount(_ query: HealthQuery, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: query.start, to: query.end).day ?? 1
        return max(days, 1)
    }

    private static func rangeLabel(_ query: HealthQuery, calendar: Calendar) -> String {
        // `end` is exclusive (start of the day after the last); show the inclusive
        // last day.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: query.end) ?? query.start
        let start = shortDate(query.start, calendar: calendar)
        let end = shortDate(lastDay, calendar: calendar)
        return start == end ? start : "\(start) – \(end)"
    }

    private static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Number formatting

    /// Compact number: integers grouped (8,432), fractional values to one decimal
    /// (75.3). Locale-independent so output is stable.
    static func number(_ value: Double) -> String {
        if value.rounded() == value {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            // en_US_POSIX doesn't group by default; force it for readable totals.
            formatter.usesGroupingSeparator = true
            formatter.groupingSize = 3
            formatter.groupingSeparator = ","
            return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// "7h 12m", "45m", or "30s" for sub-minute durations.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
