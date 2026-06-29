import Charts
import PhantasmKit
import SwiftUI

/// Renders a validated `ChartSpec` (from the `render_chart` tool) natively with
/// Swift Charts, so it follows the app theme, adapts to dark mode, and stays
/// crisp at any zoom. The model emits only structured data; this view owns all
/// rendering, theming, and the `SemanticColor` → `Color` mapping. Invalid specs
/// never reach here — `MessageBubble` shows a text fallback instead.
struct ChartView: View {
    let spec: ChartSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
                .frame(height: 240)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var header: some View {
        if spec.title != nil || spec.subtitle != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let title = spec.title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                if let subtitle = spec.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var chart: some View {
        switch spec.type {
        case .pie:
            pieChart
        default:
            cartesianChart
        }
    }

    // MARK: - Pie

    private var pieChart: some View {
        // A pie reads from a single series; each data point is one slice. Slices
        // get palette colors by position (a single explicit series color can't
        // distinguish slices).
        let slices = Array((spec.series.first?.data ?? []).enumerated())
        return Chart(slices, id: \.offset) { _, point in
            SectorMark(
                angle: .value(spec.yAxisLabel ?? "Value", point.y),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(by: .value("Slice", point.x))
        }
        .chartForegroundStyleScale(domain: sliceLabels, range: sliceColors)
    }

    // MARK: - Cartesian (bar / line / area / point)

    @ViewBuilder private var cartesianChart: some View {
        let xName = spec.xAxisLabel ?? "x"
        if spec.isTimeSeries {
            // Every x parsed as an ISO-8601 date → a real, self-sorting date axis.
            Chart {
                marks { point in
                    .value(xName, ChartSpec.parseISODate(point.x) ?? .distantPast)
                }
            }
            .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
            .chartXAxisLabel(spec.xAxisLabel ?? "")
            .chartYAxisLabel(spec.yAxisLabel ?? "")
        } else {
            // Categorical x: pin the scale domain to the model's order so the axis
            // isn't re-sorted alphabetically (Jan, Feb, … stays put).
            Chart {
                marks { point in .value(xName, point.x) }
            }
            .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
            .chartXScale(domain: orderedXLabels)
            .chartXAxisLabel(spec.xAxisLabel ?? "")
            .chartYAxisLabel(spec.yAxisLabel ?? "")
        }
    }

    /// Builds the marks for every point across every series, mapping x through
    /// `xValue` so the same body serves both the date and categorical axes.
    @ChartContentBuilder
    private func marks<X: Plottable>(
        x xValue: @escaping (ChartSpec.DataPoint) -> PlottableValue<X>
    ) -> some ChartContent {
        ForEach(Array(spec.series.enumerated()), id: \.offset) { _, series in
            ForEach(Array(series.data.enumerated()), id: \.offset) { _, point in
                mark(x: xValue(point), y: point.y, series: series.name)
            }
        }
    }

    @ChartContentBuilder
    private func mark<X: Plottable>(
        x: PlottableValue<X>,
        y: Double,
        series name: String
    ) -> some ChartContent {
        let yValue = PlottableValue.value(spec.yAxisLabel ?? "Value", y)
        let color = PlottableValue.value("Series", name)
        switch spec.type {
        case .bar:
            BarMark(x: x, y: yValue)
                .foregroundStyle(by: color)
                .position(by: color)
        case .area:
            AreaMark(x: x, y: yValue)
                .foregroundStyle(by: color)
        case .point:
            PointMark(x: x, y: yValue)
                .foregroundStyle(by: color)
        case .line:
            LineMark(x: x, y: yValue)
                .foregroundStyle(by: color)
                .symbol(by: color)
        case .pie:
            // Unreachable: pie routes to `pieChart`. A harmless mark keeps the
            // switch exhaustive.
            LineMark(x: x, y: yValue)
        }
    }

    // MARK: - Colors + ordering

    /// The fixed palette, in case order — used to assign a color to any series or
    /// slice the model didn't color explicitly.
    private var palette: [SemanticColor] { SemanticColor.allCases }

    private var seriesNames: [String] { spec.series.map(\.name) }

    /// One color per series: the model's choice, or a palette color by position.
    private var seriesColors: [Color] {
        spec.series.enumerated().map { index, series in
            (series.color ?? palette[index % palette.count]).color
        }
    }

    private var sliceLabels: [String] { (spec.series.first?.data ?? []).map(\.x) }

    private var sliceColors: [Color] {
        (spec.series.first?.data ?? []).indices.map { palette[$0 % palette.count].color }
    }

    /// Unique x labels in first-seen order, used as the categorical x domain.
    private var orderedXLabels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for series in spec.series {
            for point in series.data where seen.insert(point.x).inserted {
                out.append(point.x)
            }
        }
        return out
    }
}

#Preview("Charts") {
    ScrollView {
        VStack(spacing: 16) {
            ChartView(spec: ChartSpec(
                type: .bar, title: "Revenue by quarter", subtitle: "FY2024 vs FY2023",
                xAxisLabel: "Quarter", yAxisLabel: "USD (k)",
                series: [
                    .init(name: "2023", color: .gray, data: [
                        .init(x: "Q1", y: 8), .init(x: "Q2", y: 11),
                        .init(x: "Q3", y: 9), .init(x: "Q4", y: 13),
                    ]),
                    .init(name: "2024", color: .blue, data: [
                        .init(x: "Q1", y: 10), .init(x: "Q2", y: 14),
                        .init(x: "Q3", y: 12), .init(x: "Q4", y: 18),
                    ]),
                ]
            ))
            ChartView(spec: ChartSpec(
                type: .line, title: "Daily active users",
                xAxisLabel: "Date", yAxisLabel: "Users",
                series: [.init(name: "DAU", color: .green, data: [
                    .init(x: "2024-01-01", y: 120), .init(x: "2024-01-08", y: 160),
                    .init(x: "2024-01-15", y: 140), .init(x: "2024-01-22", y: 210),
                ])]
            ))
            ChartView(spec: ChartSpec(
                type: .pie, title: "Traffic by source",
                series: [.init(name: "share", data: [
                    .init(x: "Direct", y: 35), .init(x: "Search", y: 40),
                    .init(x: "Social", y: 15), .init(x: "Referral", y: 10),
                ])]
            ))
            ChartView(spec: ChartSpec(
                type: .point, title: "Height vs weight", xAxisLabel: "cm", yAxisLabel: "kg",
                series: [.init(name: "sample", color: .purple, data: [
                    .init(x: "160", y: 55), .init(x: "170", y: 68),
                    .init(x: "180", y: 80), .init(x: "190", y: 92),
                ])]
            ))
        }
        .padding()
    }
}

extension SemanticColor {
    /// The themed SwiftUI color for this case. This is the ONLY place chart colors
    /// are defined; SwiftUI's system palette is already light/dark adaptive, so
    /// dark-mode handling lives here too.
    var color: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        case .teal: .teal
        case .yellow: .yellow
        case .gray: .gray
        }
    }
}
