import Foundation
import Testing
@testable import PhantasmKit

struct RenderChartToolTests {
    private let tool = RenderChartTool()

    private func call(_ arguments: String?) -> WireToolCall {
        WireToolCall(
            id: "c1", function: .init(name: ToolName.renderChart, arguments: arguments)
        )
    }

    @Test func advertisesContractSchema() {
        #expect(tool.name == "render_chart")
        // The schema is advertised in the request's app-tool list.
        #expect(AppTools.all.contains { $0.function.name == "render_chart" })
    }

    @Test func resolveAcknowledgesValidChart() async {
        let json = #"{"type":"bar","title":"Sales","series":[{"name":"a","data":[{"x":"Q1","y":3}]}]}"#
        let result = await tool.resolve(call(json))
        #expect(result.contains("bar chart"))
        #expect(result.contains("Sales")) // title echoed back
        #expect(!result.contains("failed"))
    }

    @Test func resolveReportsInvalidChartToModel() async {
        // Oversized pie: the model gets the reason so it can switch to a bar chart.
        let slices = (1...7).map { #"{"x":"S\#($0)","y":\#($0)}"# }.joined(separator: ",")
        let json = #"{"type":"pie","series":[{"name":"a","data":[\#(slices)]}]}"#
        let result = await tool.resolve(call(json))
        #expect(result.contains("render_chart failed"))
        #expect(result.contains("at most 6 slices"))
    }

    @Test func resolveHandlesMalformedArgumentsWithoutCrashing() async {
        let result = await tool.resolve(call("{ not json"))
        #expect(result.contains("render_chart failed"))
    }
}
