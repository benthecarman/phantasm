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

    func testParseKeepsNutritionMetrics() {
        let parsed = HealthTool.parseQuery(
            #"{"metrics":["dietary_energy","dietary_protein","dietary_water","dietary_sodium"]}"#,
            now: day(2026, 6, 29),
            calendar: utc
        )
        XCTAssertEqual(
            parsed?.metrics,
            [.dietaryEnergy, .dietaryProtein, .dietaryWater, .dietarySodium])
    }

    func testParseKeepsSexualActivityMetric() {
        let parsed = HealthTool.parseQuery(
            #"{"metrics":["sexual_activity"]}"#,
            now: day(2026, 6, 29),
            calendar: utc
        )
        XCTAssertEqual(parsed?.metrics, [.sexualActivity])
    }

    func testParseKeepsCycleTrackingMetrics() {
        let parsed = HealthTool.parseQuery(
            #"{"metrics":["menstrual_flow","ovulation_test_result","cervical_mucus_quality","basal_body_temperature","pregnancy_test_result"]}"#,
            now: day(2026, 6, 29),
            calendar: utc
        )
        XCTAssertEqual(
            parsed?.metrics,
            [
                .menstrualFlow, .ovulationTestResult, .cervicalMucusQuality,
                .basalBodyTemperature, .pregnancyTestResult,
            ])
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

    func testParseGranularityDefaultsToSummaryAndAcceptsDaily() {
        let summary = HealthTool.parseQuery(
            #"{"metrics":["steps"]}"#, now: day(2026, 6, 29), calendar: utc
        )
        XCTAssertEqual(summary?.granularity, .summary)

        let daily = HealthTool.parseQuery(
            #"{"metrics":["steps"],"granularity":"daily"}"#,
            now: day(2026, 6, 29), calendar: utc
        )
        XCTAssertEqual(daily?.granularity, .daily)
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

    func testCumulativeFormatsDailyBucketsWhenRequested() {
        let result = HealthMetricResult(
            metric: .steps,
            reading: .quantity(HealthSummary(
                unit: "steps",
                sum: 3000,
                daily: [
                    HealthQuantityBucket(
                        start: day(2026, 6, 28), end: day(2026, 6, 29), sum: 1000),
                    HealthQuantityBucket(
                        start: day(2026, 6, 29), end: day(2026, 6, 30), sum: 2000),
                ])))
        let block = HealthTool.format(
            query: HealthQuery(
                metrics: [.steps], start: day(2026, 6, 28), end: day(2026, 6, 30),
                granularity: .daily),
            results: [result],
            calendar: utc)
        XCTAssertTrue(block.contains("steps: 3,000 steps total"))
        XCTAssertTrue(block.contains("daily: Jun 28, 2026 1,000 steps; Jun 29, 2026 2,000 steps"))
    }

    func testNutritionMetricsFormatAsCumulativeTotals() {
        let block = HealthTool.format(
            query: query(
                [.dietaryEnergy, .dietaryProtein, .dietaryWater],
                day(2026, 6, 29),
                day(2026, 6, 30)),
            results: [
                HealthMetricResult(
                    metric: .dietaryEnergy,
                    reading: .quantity(HealthSummary(unit: "kcal", sum: 2180))),
                HealthMetricResult(
                    metric: .dietaryProtein,
                    reading: .quantity(HealthSummary(unit: "g", sum: 132.5))),
                HealthMetricResult(
                    metric: .dietaryWater,
                    reading: .quantity(HealthSummary(unit: "mL", sum: 2400))),
            ],
            calendar: utc)

        XCTAssertTrue(block.contains("dietary_energy: 2,180 kcal total"))
        XCTAssertTrue(block.contains("dietary_protein: 132.5 g total"))
        XCTAssertTrue(block.contains("dietary_water: 2,400 mL total"))
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

    func testSleepFormatsDailyBucketsWhenRequested() {
        let result = HealthMetricResult(
            metric: .sleep,
            reading: .sleep(HealthSleepSummary(
                asleep: 50400,
                inBed: 54000,
                daily: [
                    HealthSleepBucket(day: day(2026, 6, 28), asleep: 21600, inBed: 23400),
                    HealthSleepBucket(
                        day: day(2026, 6, 29), asleep: 28800, inBed: 30600, deep: 4200),
                ])))
        let block = HealthTool.format(
            query: HealthQuery(
                metrics: [.sleep], start: day(2026, 6, 28), end: day(2026, 6, 30),
                granularity: .daily),
            results: [result],
            calendar: utc)
        XCTAssertTrue(block.contains("sleep: 14h asleep, 15h in bed"))
        XCTAssertTrue(block.contains("daily: Jun 28: 6h asleep, 6h 30m in bed; Jun 29: 8h asleep, 8h 30m in bed [deep 1h 10m]"))
    }

    func testSexualActivityFormatsEventCountAndProtectionCounts() {
        let result = HealthMetricResult(
            metric: .sexualActivity,
            reading: .events(HealthEventSummary(
                count: 3,
                protectedCount: 2,
                unprotectedCount: 0,
                protectionUnknownCount: 1)))
        let block = HealthTool.format(
            query: query([.sexualActivity], day(2026, 6, 22), day(2026, 6, 30)),
            results: [result],
            calendar: utc)

        XCTAssertTrue(block.contains(
            "sexual_activity: 3 events total (2 protected, 0 unprotected, 1 protection unknown)"))
    }

    func testSexualActivityFormatsDailyBucketsWhenRequested() {
        let result = HealthMetricResult(
            metric: .sexualActivity,
            reading: .events(HealthEventSummary(
                count: 3,
                protectedCount: 1,
                unprotectedCount: 1,
                protectionUnknownCount: 1,
                daily: [
                    HealthEventBucket(
                        day: day(2026, 6, 28),
                        count: 1,
                        protectedCount: 1,
                        unprotectedCount: 0,
                        protectionUnknownCount: 0),
                    HealthEventBucket(
                        day: day(2026, 6, 29),
                        count: 2,
                        protectedCount: 0,
                        unprotectedCount: 1,
                        protectionUnknownCount: 1),
                ])))
        let block = HealthTool.format(
            query: HealthQuery(
                metrics: [.sexualActivity],
                start: day(2026, 6, 28),
                end: day(2026, 6, 30),
                granularity: .daily),
            results: [result],
            calendar: utc)

        XCTAssertTrue(block.contains("sexual_activity: 3 events total"))
        XCTAssertTrue(block.contains(
            "daily: Jun 28, 2026 1 event (1 protected, 0 unprotected); Jun 29, 2026 2 events (0 protected, 1 unprotected, 1 protection unknown)"))
    }

    func testCycleTrackingFormatsEventBreakdown() {
        let result = HealthMetricResult(
            metric: .menstrualFlow,
            reading: .events(HealthEventSummary(
                count: 4,
                breakdown: [
                    HealthEventBreakdown(label: "light", count: 1),
                    HealthEventBreakdown(label: "heavy", count: 2),
                    HealthEventBreakdown(label: "cycle_start", count: 1),
                ])))
        let block = HealthTool.format(
            query: query([.menstrualFlow], day(2026, 6, 22), day(2026, 6, 30)),
            results: [result],
            calendar: utc)

        XCTAssertTrue(block.contains(
            "menstrual_flow: 4 events total (light 1, heavy 2, cycle_start 1)"))
    }

    func testCycleTrackingFormatsDailyBreakdownsWhenRequested() {
        let result = HealthMetricResult(
            metric: .pregnancyTestResult,
            reading: .events(HealthEventSummary(
                count: 3,
                breakdown: [
                    HealthEventBreakdown(label: "negative", count: 1),
                    HealthEventBreakdown(label: "positive", count: 1),
                    HealthEventBreakdown(label: "indeterminate", count: 1),
                ],
                daily: [
                    HealthEventBucket(
                        day: day(2026, 6, 28),
                        count: 1,
                        breakdown: [HealthEventBreakdown(label: "negative", count: 1)]),
                    HealthEventBucket(
                        day: day(2026, 6, 29),
                        count: 2,
                        breakdown: [
                            HealthEventBreakdown(label: "positive", count: 1),
                            HealthEventBreakdown(label: "indeterminate", count: 1),
                        ]),
                ])))
        let block = HealthTool.format(
            query: HealthQuery(
                metrics: [.pregnancyTestResult],
                start: day(2026, 6, 28),
                end: day(2026, 6, 30),
                granularity: .daily),
            results: [result],
            calendar: utc)

        XCTAssertTrue(block.contains(
            "pregnancy_test_result: 3 events total (negative 1, positive 1, indeterminate 1)"))
        XCTAssertTrue(block.contains(
            "daily: Jun 28, 2026 1 event (negative 1); Jun 29, 2026 2 events (positive 1, indeterminate 1)"))
    }

    func testBasalBodyTemperatureFormatsAsDiscreteMetric() {
        let result = HealthMetricResult(
            metric: .basalBodyTemperature,
            reading: .quantity(HealthSummary(
                unit: "degC", average: 36.6, minimum: 36.3, maximum: 36.9)))
        let block = HealthTool.format(
            query: query([.basalBodyTemperature], day(2026, 6, 29), day(2026, 6, 30)),
            results: [result],
            calendar: utc)

        XCTAssertTrue(block.contains(
            "basal_body_temperature: avg 36.6 degC (min 36.3, max 36.9)"))
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
