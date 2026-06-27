import XCTest
@testable import PhantasmKit

final class CurrentTimeToolTests: XCTestCase {
    /// A fixed instant: 2026-06-26T20:07:42Z (a Friday).
    private let instant = Date(timeIntervalSince1970: 1_782_504_462)

    private func call(
        name: String = ToolName.currentTime,
        id: String? = "call_1",
        arguments: String = "{}"
    ) -> WireToolCall {
        WireToolCall(
            index: 0,
            id: id,
            type: "function",
            function: WireToolCall.Function(name: name, arguments: arguments)
        )
    }

    func testHandlesOnlyCurrentTimeCalls() {
        XCTAssertTrue(CurrentTimeTool.handles([call()]))
        XCTAssertFalse(CurrentTimeTool.handles([call(name: ToolName.askUser)]))
        XCTAssertFalse(CurrentTimeTool.handles([]))
    }

    func testResolveReturnsNilForOtherTools() {
        XCTAssertNil(CurrentTimeTool.resolve(call(name: ToolName.askUser), now: instant))
    }

    func testExplicitUTC() {
        let out = CurrentTimeTool.format(now: instant, requested: "UTC")
        XCTAssertTrue(out.contains("timezone: UTC"))
        XCTAssertTrue(out.contains("iso8601: 2026-06-26T20:07:42Z"))
        // UTC is its own utc, so no redundant `utc:` line.
        XCTAssertFalse(out.contains("utc: "))
        XCTAssertTrue(out.contains(" PM") || out.contains(" AM"))
    }

    func testIANATimezone() {
        let out = CurrentTimeTool.format(now: instant, requested: "America/Chicago")
        XCTAssertTrue(out.contains("timezone: America/Chicago"))
        // 20:07 UTC is 15:07 CDT (UTC-5 in June).
        XCTAssertTrue(out.contains("iso8601: 2026-06-26T15:07:42-05:00"))
        XCTAssertTrue(out.contains("clock: Friday, June 26, 2026 at 3:07:42 PM"))
        XCTAssertTrue(out.contains("utc: 2026-06-26T20:07:42Z"))
    }

    func testFixedOffset() {
        let out = CurrentTimeTool.format(now: instant, requested: "-05:00")
        XCTAssertTrue(out.contains("timezone: UTC-05:00"))
        XCTAssertTrue(out.contains("iso8601: 2026-06-26T15:07:42-05:00"))
        XCTAssertTrue(out.contains("utc: 2026-06-26T20:07:42Z"))
    }

    func testUnknownTimezoneIsRecoverableError() {
        let out = CurrentTimeTool.format(now: instant, requested: "Mars/Olympus")
        XCTAssertTrue(out.hasPrefix("current_time failed:"))
    }

    func testEmptyAndMissingTimezoneUseDeviceZone() {
        // No assertion on the zone label (host-dependent), only that it produced a
        // well-formed block rather than erroring or defaulting away from device.
        for requested in [nil, "", "  "] as [String?] {
            let out = CurrentTimeTool.format(now: instant, requested: requested)
            XCTAssertTrue(out.hasPrefix("Current time:\ntimezone: "))
            XCTAssertTrue(out.contains("clock: "))
            XCTAssertTrue(out.contains("iso8601: "))
        }
    }

    func testSpecCarriesDeviceTimezone() {
        // The schema sent to the model each turn names the device's live timezone,
        // so the model knows where the user is.
        let zone = TimeZone.current.identifier
        let description = CurrentTimeTool().spec.function.description
        XCTAssertEqual(description?.contains(zone), true)
    }

    func testResolveParsesTimezoneArgument() {
        let out = CurrentTimeTool.resolve(
            call(arguments: #"{"timezone":"UTC"}"#), now: instant
        )
        XCTAssertEqual(out, "Current time:\ntimezone: UTC\n"
            + "clock: \(clockUTC)\niso8601: 2026-06-26T20:07:42Z")
    }

    /// The expected UTC clock string for `instant`, computed the same way the tool
    /// does (locale/format are fixed, so this is stable).
    private var clockUTC: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        return f.string(from: instant)
    }
}
