import XCTest
@testable import PhantasmKit

final class ReasoningDurationTests: XCTestCase {
    func testFormatsSecondsWithPluralization() {
        XCTAssertEqual(ReasoningDuration.format(0.2), "1 second")
        XCTAssertEqual(ReasoningDuration.format(11.6), "12 seconds")
    }

    func testFormatsMinutesAndRemainingSeconds() {
        XCTAssertEqual(ReasoningDuration.format(60), "1 minute")
        XCTAssertEqual(ReasoningDuration.format(121), "2 minutes 1 second")
    }
}
