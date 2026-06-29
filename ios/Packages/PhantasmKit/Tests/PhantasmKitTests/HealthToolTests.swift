import XCTest
@testable import PhantasmKit

final class HealthToolTests: XCTestCase {
    // A fixed UTC calendar so range math + date formatting are deterministic
    // regardless of where the test host runs.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func call(arguments: String) -> WireToolCall {
        WireToolCall(
            index: 0, id: "h", type: "function",
            function: WireToolCall.Function(name: ToolName.health, arguments: arguments)
        )
    }

    private func query(_ metrics: [HealthMetric], _ start: Date, _ end: Date) -> HealthQuery {
        HealthQuery(metrics: metrics, start: start, end: end)
    }

    // MARK: - Parsing

    func testParseDropsUnknownMetricsAndKeepsKnown() {
        let parsed = HealthTool.parseQuery(
            #"{"metrics":["steps","bogus","heart_rate"]}"#, now: day(2026, 6, 29), calendar: utc
        )
        XCTAssertEqual(parsed?.metrics, [.steps, .heartRate])
    }

    func testParseReturnsNilWhenNoValidMetrics() {
        XCTAssertNil(HealthTool.parseQuery(#"{"metrics":[]}"#, now: day(2026, 6, 29), calendar: utc))
        XCTAssertNil(HealthTool.parseQuery(#"{"metrics":["nope"]}"#, now: day(2026, 6, 29), calendar: utc))
        XCTAssertNil(HealthTool.parseQuery("not json", now: day(2026, 6, 29), calendar: utc))
    }

    func testDateRangeDefaultsToToday() {
        let range = HealthTool.dateRange(
            period: nil, startDate: nil, endDate: nil, now: day(2026, 6, 29), calendar: utc)
        XCTAssertEqual(range.start, day(2026, 6, 29))
        XCTAssertEqual(range.end, day(2026, 6, 30))
    }

    func testDateRangeLast7Days() {
        let range = HealthTool.dateRange(
            period: "last_7_days", startDate: nil, endDate: nil, now: day(2026, 6, 29), calendar: utc)
        XCTAssertEqual(range.start, day(2026, 6, 23))
        XCTAssertEqual(range.end, day(2026, 6, 30))
    }

    func testExplicitDatesOverridePeriodAndAreInclusive() {
        let range = HealthTool.dateRange(
            period: "last_30_days", startDate: "2026-06-01", endDate: "2026-06-07",
            now: day(2026, 6, 29), calendar: utc)
        XCTAssertEqual(range.start, day(2026, 6, 1))
        XCTAssertEqual(range.end, day(2026, 6, 8)) // exclusive end = day after the 7th
    }

    // MARK: - Formatting

    func testCumulativeFormatsTotalAndDailyAverageOverMultiDayRange() {
        let result = HealthMetricResult(
            metric: .steps, reading: .quantity(HealthSummary(unit: "steps", sum: 8432)))
        let block = HealthTool.format(
            query: query([.steps], day(2026, 6, 23), day(2026, 6, 30)),
            results: [result], calendar: utc)
        XCTAssertTrue(block.contains("steps: 8,432 steps total"))
        XCTAssertTrue(block.contains("avg")) // 7-day range → daily average shown
    }

    func testCumulativeOmitsDailyAverageForSingleDay() {
        let result = HealthMetricResult(
            metric: .steps, reading: .quantity(HealthSummary(unit: "steps", sum: 8432)))
        let block = HealthTool.format(
            query: query([.steps], day(2026, 6, 29), day(2026, 6, 30)),
            results: [result], calendar: utc)
        XCTAssertTrue(block.contains("steps: 8,432 steps total"))
        XCTAssertFalse(block.contains("avg"))
    }

    func testDiscreteFormatsAverageWithMinMax() {
        let result = HealthMetricResult(
            metric: .heartRate,
            reading: .quantity(HealthSummary(
                unit: "bpm", average: 72.4, minimum: 54, maximum: 141)))
        let block = HealthTool.format(
            query: query([.heartRate], day(2026, 6, 29), day(2026, 6, 30)),
            results: [result], calendar: utc)
        XCTAssertTrue(block.contains("heart_rate: avg 72.4 bpm (min 54, max 141)"))
    }

    func testLatestFormatsValueWithDate() {
        let result = HealthMetricResult(
            metric: .weight,
            reading: .quantity(HealthSummary(
                unit: "kg", latest: 75.3, latestDate: day(2026, 6, 28))))
        let block = HealthTool.format(
            query: query([.weight], day(2026, 6, 22), day(2026, 6, 30)),
            results: [result], calendar: utc)
        XCTAssertTrue(block.contains("weight: 75.3 kg (as of Jun 28, 2026)"))
    }

    func testSleepFormatsAsleepInBedAndStages() {
        let result = HealthMetricResult(
            metric: .sleep,
            reading: .sleep(HealthSleepSummary(
                asleep: 25920, inBed: 28920, deep: 3600, rem: 5400)))
        let block = HealthTool.format(
            query: query([.sleep], day(2026, 6, 29), day(2026, 6, 30)),
            results: [result], calendar: utc)
        XCTAssertTrue(block.contains("sleep: 7h 12m asleep, 8h 2m in bed"))
        XCTAssertTrue(block.contains("deep 1h"))
        XCTAssertTrue(block.contains("REM 1h 30m"))
    }

    func testWorkoutsFormatsCountActivityAndMetrics() {
        let result = HealthMetricResult(
            metric: .workouts,
            reading: .workouts([
                HealthWorkout(
                    activity: "Running", start: day(2026, 6, 27),
                    duration: 1920, energyKcal: 310, distanceMeters: 5000),
            ]))
        let block = HealthTool.format(
            query: query([.workouts], day(2026, 6, 22), day(2026, 6, 30)),
            results: [result], calendar: utc)
        XCTAssertTrue(block.contains("workouts: 1 — Running 32m 310 kcal 5 km (Jun 27, 2026)"))
    }

    func testNoDataAndUnavailableLines() {
        let block = HealthTool.format(
            query: query([.steps, .weight], day(2026, 6, 29), day(2026, 6, 30)),
            results: [
                HealthMetricResult(metric: .steps, reading: .noData),
                HealthMetricResult(metric: .weight, reading: .unavailable("read error")),
            ],
            calendar: utc)
        XCTAssertTrue(block.contains("steps: no data in range"))
        XCTAssertTrue(block.contains("weight: read error"))
    }

    // MARK: - Resolution + registry

    func testResolveSuccessFormatsResults() async {
        let provider = StubHealthProvider(result: .success([
            HealthMetricResult(metric: .steps, reading: .quantity(HealthSummary(unit: "steps", sum: 100))),
        ]))
        let tool = HealthTool(provider: provider)
        let result = await tool.resolve(call(arguments: #"{"metrics":["steps"]}"#))
        XCTAssertTrue(result.hasPrefix("Health data ("))
        XCTAssertTrue(result.contains("steps: 100 steps total"))
    }

    func testResolveFailureFoldsErrorIntoResult() async {
        let tool = HealthTool(provider: StubHealthProvider(result: .failure(.unavailable)))
        let result = await tool.resolve(call(arguments: #"{"metrics":["steps"]}"#))
        XCTAssertTrue(result.hasPrefix("get_health_data failed:"))
        XCTAssertTrue(result.contains("isn't available"))
    }

    func testResolveRejectsEmptyMetrics() async {
        let tool = HealthTool(provider: StubHealthProvider(result: .success([])))
        let result = await tool.resolve(call(arguments: #"{"metrics":[]}"#))
        XCTAssertTrue(result.hasPrefix("get_health_data failed: no valid metrics"))
    }

    func testRegistryRoutesHealthOnceConfigured() {
        AppToolRegistry.configureHealth(provider: StubHealthProvider(result: .success([])))
        XCTAssertTrue(AppToolRegistry.specs.map(\.function.name).contains(ToolName.health))
        XCTAssertTrue(AppToolRegistry.isAutoResolved(name: ToolName.health))
        if case .auto = AppToolRegistry.match(call(arguments: "{}")) {} else {
            XCTFail("health should classify as an auto-resolved tool")
        }
    }
}

private struct StubHealthProvider: HealthProviding {
    let result: Result<[HealthMetricResult], HealthLookupError>
    func read(_ query: HealthQuery) async -> Result<[HealthMetricResult], HealthLookupError> {
        result
    }
}
