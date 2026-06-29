import Foundation

/// The structured data the model emits via the app-hosted `render_chart` tool.
/// The app renders it natively with Swift Charts, so the model never produces
/// code, HTML, or colors — only this shape. Pure value type (no Charts/SwiftUI)
/// so it decodes and unit-tests on the host; the app target owns all rendering
/// and the `SemanticColor` → `Color` mapping.
///
/// Mirrors the tool's JSON schema exactly (see `RenderChartTool.spec`). Decoding
/// is followed by `validate()` because the schema can't express every constraint
/// (non-empty data, pie slice cap, finite numbers) and the model will eventually
/// send something odd — on an invalid spec the caller shows a plain-text bubble
/// instead of rendering something broken.
public struct ChartSpec: Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case bar, line, area, point, pie
    }

    public let type: Kind
    public let title: String?
    public let subtitle: String?
    public let xAxisLabel: String?
    public let yAxisLabel: String?
    public let series: [Series]

    public init(
        type: Kind,
        title: String? = nil,
        subtitle: String? = nil,
        xAxisLabel: String? = nil,
        yAxisLabel: String? = nil,
        series: [Series]
    ) {
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.xAxisLabel = xAxisLabel
        self.yAxisLabel = yAxisLabel
        self.series = series
    }

    public struct Series: Equatable, Sendable, Codable {
        public let name: String
        public let color: SemanticColor?
        public let data: [DataPoint]

        public init(name: String, color: SemanticColor? = nil, data: [DataPoint]) {
            self.name = name
            self.color = color
            self.data = data
        }

        private enum CodingKeys: String, CodingKey { case name, color, data }

        /// Decode `color` leniently: an unknown or missing color is dropped to
        /// `nil` (the renderer assigns one by position) rather than failing the
        /// whole decode — the model occasionally invents a color name.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            data = try c.decode([DataPoint].self, forKey: .data)
            color = (try? c.decodeIfPresent(SemanticColor.self, forKey: .color)) ?? nil
        }
    }

    /// One point. `x` is ALWAYS a string — a short category label, or an ISO-8601
    /// date for time axes (the renderer detects which). `y` is the magnitude.
    public struct DataPoint: Equatable, Sendable, Codable {
        public let x: String
        public let y: Double

        public init(x: String, y: Double) {
            self.x = x
            self.y = y
        }
    }
}

// MARK: - Semantic colors

/// The only color vocabulary the model may use. The case → SwiftUI `Color`
/// mapping (and its light/dark adaptation) lives in the app target — this enum
/// is the single source of truth for *which* colors exist, never their values.
public enum SemanticColor: String, Sendable, Codable, CaseIterable {
    case blue, green, orange, red, purple, teal, yellow, gray
}

// MARK: - Decoding + validation

public extension ChartSpec {
    /// Why a decoded (or undecodable) spec can't be rendered. The message is
    /// shown to the user in the fallback bubble *and* returned to the model (via
    /// the tool result) so it can correct itself.
    enum ValidationError: Error, Equatable, Sendable {
        case malformed
        case emptySeries
        case emptyData(series: String)
        case tooManyPieSlices(count: Int)
        case nonFiniteValue(series: String)

        public var message: String {
            switch self {
            case .malformed:
                "The chart data could not be read."
            case .emptySeries:
                "The chart had no series to plot."
            case let .emptyData(series):
                "Series \"\(series)\" had no data points."
            case let .tooManyPieSlices(count):
                "A pie chart supports at most 6 slices (got \(count)); use a bar chart instead."
            case let .nonFiniteValue(series):
                "Series \"\(series)\" contained a value that isn't a finite number."
            }
        }
    }

    /// Maximum slices a pie chart stays readable at. Beyond this we reject and
    /// suggest a bar chart instead of rendering an unreadable wheel.
    static let maxPieSlices = 6

    /// Decode the tool call's JSON `arguments` string into a validated spec, or an
    /// error describing why it can't be rendered. Never traps — malformed JSON,
    /// missing fields, and out-of-range numbers all fold into `.failure`.
    static func decode(fromArguments arguments: String?) -> Result<ChartSpec, ValidationError> {
        guard let arguments, let data = arguments.data(using: .utf8) else {
            return .failure(.malformed)
        }
        // Plain decoder (no key strategy): the schema keys are camelCase and reach
        // the model verbatim, so its arguments come back camelCase too.
        guard let spec = try? JSONDecoder().decode(ChartSpec.self, from: data) else {
            return .failure(.malformed)
        }
        if let error = spec.validationError { return .failure(error) }
        return .success(spec)
    }

    /// The first reason this spec can't be rendered, or nil when it's drawable.
    var validationError: ValidationError? {
        guard !series.isEmpty else { return .emptySeries }
        for s in series {
            if s.data.isEmpty { return .emptyData(series: s.name) }
            if s.data.contains(where: { !$0.y.isFinite }) {
                return .nonFiniteValue(series: s.name)
            }
        }
        if type == .pie {
            // A pie draws from the first series; each point is one slice.
            let slices = series.first?.data.count ?? 0
            if slices > Self.maxPieSlices { return .tooManyPieSlices(count: slices) }
        }
        return nil
    }
}

// MARK: - Axis kind

public extension ChartSpec {
    /// True when every `x` across every series parses as an ISO-8601 date — the
    /// renderer then uses a real date axis. Otherwise `x` values are treated as
    /// ordered categories. An empty spec is not a time series.
    var isTimeSeries: Bool {
        let points = series.flatMap(\.data)
        guard !points.isEmpty else { return false }
        return points.allSatisfy { Self.parseISODate($0.x) != nil }
    }

    /// Parse an ISO-8601 date string. Accepts a full date-time (with or without
    /// fractional seconds) or a bare calendar date (`yyyy-MM-dd`), the two shapes
    /// the model is told to use for time axes.
    static func parseISODate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let date = isoDateTime.date(from: trimmed) { return date }
        if let date = isoDateTimeFractional.date(from: trimmed) { return date }
        return isoDateOnly.date(from: trimmed)
    }

    private static let isoDateTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoDateTimeFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
