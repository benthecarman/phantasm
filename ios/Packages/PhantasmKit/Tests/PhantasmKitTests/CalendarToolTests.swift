import XCTest
@testable import PhantasmKit

final class CalendarToolTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = utc
        components.timeZone = utc.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    private func call(arguments: String? = "{}") -> WireToolCall {
        WireToolCall(
            id: "cal",
            function: WireToolCall.Function(name: ToolName.calendar, arguments: arguments)
        )
    }

    private func createCall(arguments: String? = "{}") -> WireToolCall {
        WireToolCall(
            id: "create_cal",
            function: WireToolCall.Function(name: ToolName.createCalendarEvent, arguments: arguments)
        )
    }

    func testParseQueryDefaultsToUpcomingWeek() {
        let now = day(2026, 6, 29, hour: 12)

        let query = CalendarTool.parseQuery("{}", now: now, calendar: utc)

        XCTAssertEqual(query?.start, now)
        XCTAssertEqual(query?.end, day(2026, 7, 6, hour: 12))
        XCTAssertEqual(query?.maxResults, CalendarTool.defaultMaxResults)
        XCTAssertEqual(query?.calendarNames, [])
        XCTAssertFalse(query?.includeNotes ?? true)
    }

    func testParseQueryReadsExplicitRangeAndFilters() {
        let query = CalendarTool.parseQuery(
            """
            {
              "start_date": "2026-06-29",
              "end_date": "2026-06-30",
              "query": "dentist",
              "calendars": [" Personal "],
              "include_notes": true,
              "max_results": 500
            }
            """,
            now: day(2026, 6, 29),
            calendar: utc
        )

        XCTAssertEqual(query?.start, day(2026, 6, 29))
        XCTAssertEqual(query?.end, day(2026, 6, 30))
        XCTAssertEqual(query?.matching, "dentist")
        XCTAssertEqual(query?.calendarNames, ["Personal"])
        XCTAssertEqual(query?.maxResults, CalendarTool.maxAllowedResults)
        XCTAssertTrue(query?.includeNotes ?? false)
    }

    func testParseDateAcceptsMinutesPrecisionDateTime() {
        // Models commonly emit "YYYY-MM-DDTHH:mm" (no seconds); it must parse
        // instead of silently falling back to the default query range.
        XCTAssertEqual(
            CalendarTool.parseDate("2026-07-04T15:00", calendar: utc),
            day(2026, 7, 4, hour: 15)
        )
        // Seconds and full ISO offsets still parse.
        XCTAssertEqual(
            CalendarTool.parseDate("2026-07-04T15:00:00", calendar: utc),
            day(2026, 7, 4, hour: 15)
        )
        XCTAssertEqual(
            CalendarTool.parseDate("2026-07-04T15:00:00Z", calendar: utc),
            day(2026, 7, 4, hour: 15)
        )
    }

    func testParseDateRejectsRolledOverComponents() {
        // Out-of-range components must fail, not normalize into a wrong date.
        XCTAssertNil(CalendarTool.parseDate("2026-02-31", calendar: utc))
        XCTAssertNil(CalendarTool.parseDate("2026-13-01", calendar: utc))
        XCTAssertNotNil(CalendarTool.parseDate("2026-02-28", calendar: utc))
    }

    func testParseQueryRejectsTooWideRange() {
        let query = CalendarTool.parseQuery(
            #"{"start_date":"2026-06-01","end_date":"2026-07-10"}"#,
            now: day(2026, 6, 1),
            calendar: utc
        )

        XCTAssertNil(query)
    }

    func testFormatIncludesTimesCalendarLocationAndNotes() {
        let query = CalendarEventQuery(
            start: day(2026, 6, 29),
            end: day(2026, 6, 30),
            includeNotes: true
        )
        let block = CalendarTool.format(query: query, events: [
            CalendarEvent(
                title: "Planning",
                start: day(2026, 6, 29, hour: 9),
                end: day(2026, 6, 29, hour: 10),
                calendarTitle: "Work",
                location: "Room 4",
                notes: "Bring roadmap"
            ),
        ], calendar: utc)

        XCTAssertTrue(block.contains("Calendar events (Jun 29, 2026 12:00 AM to Jun 30, 2026 12:00 AM):"))
        XCTAssertTrue(block.contains("count: 1"))
        XCTAssertTrue(block.contains("Jun 29, 2026 9:00 AM-10:00 AM | Work | Planning"))
        XCTAssertTrue(block.contains("location: Room 4"))
        XCTAssertTrue(block.contains("notes: Bring roadmap"))
    }

    func testResolveUsesProviderAndFoldsFailuresIntoResult() async {
        let event = CalendarEvent(
            title: "Standup",
            start: day(2026, 6, 29, hour: 9),
            end: day(2026, 6, 29, hour: 9),
            calendarTitle: "Work"
        )
        let success = await CalendarTool(
            provider: StubCalendarProvider(result: .success([event]))
        ).resolve(call(arguments: #"{"start_date":"2026-06-29","end_date":"2026-06-30"}"#))
        XCTAssertTrue(success.contains("Standup"))

        let failure = await CalendarTool(
            provider: StubCalendarProvider(result: .failure(.permissionDenied))
        ).resolve(call(arguments: #"{"start_date":"2026-06-29","end_date":"2026-06-30"}"#))
        XCTAssertTrue(failure.hasPrefix("get_calendar_events failed:"))
    }

    func testRegistryCanRouteConfiguredCalendarTool() {
        AppToolRegistry.configureCalendar(provider: StubCalendarProvider(result: .success([])))

        XCTAssertTrue(AppToolRegistry.specs.map(\.function.name).contains(ToolName.calendar))
        XCTAssertTrue(AppToolRegistry.specs.map(\.function.name).contains(ToolName.createCalendarEvent))
        XCTAssertTrue(AppToolRegistry.isAutoResolved(name: ToolName.calendar))
        XCTAssertFalse(AppToolRegistry.isAutoResolved(name: ToolName.createCalendarEvent))
        if case .auto = AppToolRegistry.match(call()) {
        } else {
            XCTFail("calendar tool should be auto-resolved")
        }
        if case .interactive = AppToolRegistry.match(createCall()) {
        } else {
            XCTFail("calendar create tool should be interactive")
        }
    }

    func testParseCreateEventConfirmationDefaultsTimedEnd() {
        let confirmation = CalendarCreateEventTool.parseConfirmation(
            createCall(arguments: #"{"title":"Lunch","start_date":"2026-06-29T12:30:00"}"#),
            calendar: utc
        )

        XCTAssertEqual(confirmation?.toolCallId, "create_cal")
        XCTAssertEqual(confirmation?.draft.title, "Lunch")
        XCTAssertEqual(confirmation?.draft.start, day(2026, 6, 29, hour: 12).addingTimeInterval(30 * 60))
        XCTAssertEqual(confirmation?.draft.end, day(2026, 6, 29, hour: 13).addingTimeInterval(30 * 60))
        XCTAssertFalse(confirmation?.draft.isAllDay ?? true)
    }

    func testParseCreateEventConfirmationNormalizesAllDayEvent() {
        let confirmation = CalendarCreateEventTool.parseConfirmation(
            createCall(arguments: #"{"title":"Holiday","start_date":"2026-06-29","end_date":"2026-06-29","is_all_day":true,"calendar":"Home"}"#),
            calendar: utc
        )

        XCTAssertEqual(confirmation?.draft.start, day(2026, 6, 29))
        XCTAssertEqual(confirmation?.draft.end, day(2026, 6, 30))
        XCTAssertEqual(confirmation?.draft.calendarTitle, "Home")
        XCTAssertTrue(confirmation?.draft.isAllDay ?? false)
    }

    func testCreateEventToolConfirmsThroughProvider() async throws {
        let event = CalendarEvent(
            title: "Lunch",
            start: day(2026, 6, 29, hour: 12),
            end: day(2026, 6, 29, hour: 13),
            calendarTitle: "Work"
        )
        let tool = CalendarCreateEventTool(
            provider: StubCalendarProvider(
                result: .success([]),
                createResult: .success(event)
            )
        )
        let confirmation = try XCTUnwrap(CalendarCreateEventTool.parseConfirmation(
            createCall(arguments: #"{"title":"Lunch","start_date":"2026-06-29T12:00:00"}"#),
            calendar: utc
        ))

        let result = await tool.create(confirmation)

        XCTAssertTrue(result.hasPrefix("create_calendar_event succeeded:"))
        XCTAssertTrue(result.contains("Lunch"))
    }
}

private struct StubCalendarProvider: CalendarProviding {
    let result: Result<[CalendarEvent], CalendarLookupError>
    var createResult: Result<CalendarEvent, CalendarLookupError> = .failure(.unavailable("not configured"))

    func events(matching query: CalendarEventQuery) async -> Result<[CalendarEvent], CalendarLookupError> {
        result
    }

    func createEvent(_ draft: CalendarEventDraft) async -> Result<CalendarEvent, CalendarLookupError> {
        createResult
    }
}
