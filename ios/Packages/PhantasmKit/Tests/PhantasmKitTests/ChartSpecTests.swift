import Foundation
import Testing
@testable import PhantasmKit

struct ChartSpecTests {
    // MARK: - Decoding a valid spec for each chart type

    @Test func decodesValidBarChart() throws {
        let json = """
        {"type":"bar","title":"Revenue by quarter","subtitle":"FY2024",
         "xAxisLabel":"Quarter","yAxisLabel":"USD",
         "series":[{"name":"2024","color":"blue",
           "data":[{"x":"Q1","y":10},{"x":"Q2","y":14.5}]}]}
        """
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.type == .bar)
        #expect(spec.title == "Revenue by quarter")
        #expect(spec.subtitle == "FY2024")
        #expect(spec.xAxisLabel == "Quarter")
        #expect(spec.yAxisLabel == "USD")
        #expect(spec.series.count == 1)
        #expect(spec.series[0].name == "2024")
        #expect(spec.series[0].color == .blue)
        #expect(spec.series[0].data == [.init(x: "Q1", y: 10), .init(x: "Q2", y: 14.5)])
        #expect(spec.isTimeSeries == false)
    }

    @Test func decodesValidLineChart() throws {
        let json = #"{"type":"line","series":[{"name":"a","data":[{"x":"Jan","y":1},{"x":"Feb","y":2}]}]}"#
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.type == .line)
        #expect(spec.series[0].color == nil) // color is optional
    }

    @Test func decodesValidAreaChart() throws {
        let json = #"{"type":"area","series":[{"name":"a","data":[{"x":"A","y":3}]}]}"#
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.type == .area)
    }

    @Test func decodesValidPointChart() throws {
        let json = #"{"type":"point","series":[{"name":"a","data":[{"x":"A","y":3},{"x":"B","y":9}]}]}"#
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.type == .point)
    }

    @Test func decodesValidPieChart() throws {
        let json = #"{"type":"pie","series":[{"name":"share","data":[{"x":"A","y":3},{"x":"B","y":7}]}]}"#
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.type == .pie)
        #expect(spec.series[0].data.count == 2)
    }

    // MARK: - Multi-series + time axis

    @Test func decodesMultipleSeries() throws {
        let json = """
        {"type":"line","series":[
          {"name":"2023","color":"green","data":[{"x":"Q1","y":5}]},
          {"name":"2024","color":"orange","data":[{"x":"Q1","y":8}]}]}
        """
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.series.count == 2)
        #expect(spec.series.map(\.color) == [.green, .orange])
    }

    @Test func detectsIsoDateAxis() throws {
        let json = """
        {"type":"line","series":[{"name":"a","data":[
          {"x":"2024-01-15","y":1},{"x":"2024-02-15T08:30:00Z","y":2}]}]}
        """
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.isTimeSeries)
        #expect(ChartSpec.parseISODate("2024-01-15") != nil)
        #expect(ChartSpec.parseISODate("2024-01-15T08:30:00.123Z") != nil)
        #expect(ChartSpec.parseISODate("2024-02-31") == nil)
        #expect(ChartSpec.parseISODate("Q1") == nil)
    }

    @Test func categoryAxisIsNotTimeSeries() throws {
        // A mix of date and non-date x falls back to a categorical axis.
        let json = #"{"type":"bar","series":[{"name":"a","data":[{"x":"2024-01-15","y":1},{"x":"later","y":2}]}]}"#
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.isTimeSeries == false)
    }

    // MARK: - Lenient color decoding (defensive)

    @Test func unknownColorDecodesToNil() throws {
        let json = #"{"type":"bar","series":[{"name":"a","color":"chartreuse","data":[{"x":"A","y":1}]}]}"#
        let spec = try requireSuccess(ChartSpec.decode(fromArguments: json))
        #expect(spec.series[0].color == nil) // unknown color dropped, not a decode failure
    }

    // MARK: - Invalid specs fall back instead of crashing

    @Test func rejectsMalformedJSON() {
        #expect(ChartSpec.decode(fromArguments: "not json").failureError == .malformed)
        #expect(ChartSpec.decode(fromArguments: nil).failureError == .malformed)
        #expect(ChartSpec.decode(fromArguments: "{}").failureError == .malformed) // missing required fields
    }

    @Test func rejectsEmptySeries() {
        let json = #"{"type":"bar","series":[]}"#
        #expect(ChartSpec.decode(fromArguments: json).failureError == .emptySeries)
    }

    @Test func rejectsEmptyData() {
        let json = #"{"type":"bar","series":[{"name":"a","data":[]}]}"#
        #expect(ChartSpec.decode(fromArguments: json).failureError == .emptyData(series: "a"))
    }

    @Test func rejectsOversizedPie() {
        let slices = (1...7).map { #"{"x":"S\#($0)","y":\#($0)}"# }.joined(separator: ",")
        let json = #"{"type":"pie","series":[{"name":"a","data":[\#(slices)]}]}"#
        #expect(ChartSpec.decode(fromArguments: json).failureError == .tooManyPieSlices(count: 7))
    }

    @Test func allowsPieAtSliceCap() throws {
        let slices = (1...6).map { #"{"x":"S\#($0)","y":\#($0)}"# }.joined(separator: ",")
        let json = #"{"type":"pie","series":[{"name":"a","data":[\#(slices)]}]}"#
        _ = try requireSuccess(ChartSpec.decode(fromArguments: json))
    }

    @Test func rejectsNonFiniteNumbers() {
        // JSON can't carry a NaN/inf literal, so exercise the validator directly
        // with an in-memory spec (the guard also protects any non-decode path).
        let spec = ChartSpec(
            type: .line,
            series: [.init(name: "a", data: [.init(x: "A", y: 1), .init(x: "B", y: .infinity)])]
        )
        #expect(spec.validationError == .nonFiniteValue(series: "a"))
    }

    @Test func unrepresentableNumberFallsBack() {
        // 1e999 overflows Double; the decoder rejects it — still a graceful
        // fallback (a failure result), never a crash.
        let json = #"{"type":"line","series":[{"name":"a","data":[{"x":"A","y":1e999}]}]}"#
        #expect(ChartSpec.decode(fromArguments: json).failureError != nil)
    }

    // MARK: - Helpers

    private func requireSuccess(
        _ result: Result<ChartSpec, ChartSpec.ValidationError>
    ) throws -> ChartSpec {
        switch result {
        case let .success(spec): return spec
        case let .failure(error): throw TestFailure.unexpected(error)
        }
    }

    private enum TestFailure: Error { case unexpected(ChartSpec.ValidationError) }
}

private extension Result where Success == ChartSpec, Failure == ChartSpec.ValidationError {
    var failureError: ChartSpec.ValidationError? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
