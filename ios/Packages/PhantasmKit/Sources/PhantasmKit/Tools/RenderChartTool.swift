import Foundation

/// The app-hosted `render_chart` tool. The model emits structured chart data
/// (never code, HTML, or colors) and the app draws it natively with Swift Charts,
/// so it follows the theme, adapts to dark mode, and stays crisp at any zoom.
///
/// Like `current_time`, it's an `AutoResolvedTool`: the device "answers" the call
/// itself and the turn continues automatically — but the answer is just an
/// acknowledgement. The chart itself is rendered from the call's persisted
/// `arguments` (see `ChatMessage.chartSpecs`); this `resolve` only validates them
/// and reports back so the model can fix an unrenderable spec or add prose around
/// the chart. Validation/decoding lives in `ChartSpec` so it's host-testable.
public struct RenderChartTool: AutoResolvedTool {
    public init() {}
    public let name = ToolName.renderChart
    public var statusText: String? { "drawing chart…" }

    public func resolve(_ call: WireToolCall) async -> String {
        switch ChartSpec.decode(fromArguments: call.function?.arguments) {
        case let .success(spec):
            // The chart is already on screen; keep the model-facing note short so
            // it doesn't re-describe the whole chart in prose.
            let titled = spec.title.map { " titled \"\($0)\"" } ?? ""
            return "Rendered a \(spec.type.rawValue) chart\(titled) for the user. "
                + "Add only a brief sentence of context if helpful; do not restate the data."
        case let .failure(error):
            // Non-fatal: fold the reason into the result so the model can correct
            // (e.g. switch a too-large pie to a bar) or answer in plain text.
            return "render_chart failed: \(error.message) "
                + "Fix the chart data and try again, or answer without a chart."
        }
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: ToolName.renderChart,
            description: "Render a native, interactive chart from structured data — "
                + "not text, not an image. Use it whenever the user asks to plot, graph, "
                + "chart, or visualize something, or when your answer contains numeric "
                + "data that reads better as a picture (trends over time, comparisons "
                + "across categories, distributions, proportions). Prefer a chart over a "
                + "markdown table for numeric data. Emit ONLY this structured data: the "
                + "app owns all colors and styling. Use only real data — never invent "
                + "numbers to fill a chart.\n\n"
                + "Pick `type`: `bar` (compare categories), `line`/`area` (trends, esp. "
                + "over time), `point` (correlation/scatter), `pie` (parts of a whole, "
                + "max 6 slices). Each `x` is a string: a short category label, or an "
                + "ISO-8601 date (\"2024-01-15\") for a time axis. Provide one or more "
                + "`series`; for multi-series, give each a distinct `color`. For a pie, "
                + "use a single series where each data point is one slice.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "type": .object([
                        "type": .string("string"),
                        "enum": .array(ChartSpec.Kind.allCases.map { .string($0.rawValue) }),
                        "description": .string("The kind of chart to draw."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Optional chart title."),
                    ]),
                    "subtitle": .object([
                        "type": .string("string"),
                        "description": .string("Optional secondary line under the title."),
                    ]),
                    "xAxisLabel": .object([
                        "type": .string("string"),
                        "description": .string("Optional label for the x axis."),
                    ]),
                    "yAxisLabel": .object([
                        "type": .string("string"),
                        "description": .string("Optional label for the y axis."),
                    ]),
                    "series": .object([
                        "type": .string("array"),
                        "description": .string(
                            "One or more data series. A pie chart uses a single series."),
                        "minItems": .int(1),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "name": .object([
                                    "type": .string("string"),
                                    "description": .string(
                                        "Series name, shown in the legend."),
                                ]),
                                "color": .object([
                                    "type": .string("string"),
                                    "enum": .array(
                                        SemanticColor.allCases.map { .string($0.rawValue) }),
                                    "description": .string(
                                        "Optional. Pick from this fixed palette; the app "
                                            + "themes it. Omit to let the app choose."),
                                ]),
                                "data": .object([
                                    "type": .string("array"),
                                    "description": .string("The points in this series."),
                                    "minItems": .int(1),
                                    "items": .object([
                                        "type": .string("object"),
                                        "properties": .object([
                                            "x": .object([
                                                "type": .string("string"),
                                                "description": .string(
                                                    "A category label or an ISO-8601 date."),
                                            ]),
                                            "y": .object([
                                                "type": .string("number"),
                                                "description": .string("The value at x."),
                                            ]),
                                        ]),
                                        "required": .array([.string("x"), .string("y")]),
                                    ]),
                                ]),
                            ]),
                            "required": .array([.string("name"), .string("data")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("type"), .string("series")]),
            ])
        )
    }
}
