import XCTest

/// Regression tests for the history drawer's gesture stack, born from an iOS 26
/// bug where a SwiftUI drag gesture on the rows suppressed the List's scroll
/// pan entirely (scrolling worked on iOS 18 with the same code).
///
/// These expect a pre-seeded simulator: a saved backend profile (so onboarding
/// doesn't show) and conversations titled "Test conversation N", e.g.:
///   xcrun simctl spawn <sim> defaults write com.phantasm.app phantasm.profiles -data <hex-json>
///   sqlite3 <container>/Library/Application Support/Phantasm/phantasm.sqlite "INSERT INTO conversation ..."
/// They live in their own `PhantasmUITests` scheme so the default test action
/// stays runnable on a fresh simulator.
final class SidebarScrollUITests: XCTestCase {

    func testSidebarScrollsImmediatelyAfterOpen() throws {
        let (app, list) = launchAndOpenDrawer()

        let movedOnFirstOpen = attemptScroll(list: list, label: "first-open")

        // Close (tap the scrim right of the 320pt drawer) and reopen, to compare
        // against the reported "works after close + reopen".
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.buttons["Chat history"].tap()
        Thread.sleep(forTimeInterval: 0.3)
        let movedAfterReopen = attemptScroll(list: list, label: "reopen")

        XCTAssertTrue(movedOnFirstOpen, "sidebar did not scroll on first open")
        XCTAssertTrue(movedAfterReopen, "sidebar did not scroll after reopen")
    }

    func testSwipeToDeleteStillRemovesRow() throws {
        let (app, list) = launchAndOpenDrawer()
        let rows = seededRows(in: list)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))

        let label = rows.firstMatch.label
        let start = rows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = rows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: -0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertFalse(app.staticTexts[label].exists, "row was not deleted by left swipe")
    }

    func testSwipeOnDrawerClosesDrawer() throws {
        let (app, _) = launchAndOpenDrawer()
        let header = app.staticTexts["Chats"]
        XCTAssertTrue(header.exists)
        XCTAssertGreaterThan(header.frame.minX, 0, "drawer should start on-screen")

        // Drag left from the drawer's footer strip (outside the rows, so this
        // exercises the drawer-close pan rather than a row's delete pan; and
        // away from the top of the screen, where iOS 26's scroll-edge pocket
        // overlay intercepts touches).
        let footer = app.buttons["Settings"]
        XCTAssertTrue(footer.exists)
        let start = footer.coordinate(withNormalizedOffset: CGVector(dx: 1.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -250, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.0)

        // A closed drawer sits offset fully off-screen (x = -drawerWidth). The
        // element stays in the XCUI snapshot, so assert on geometry instead.
        XCTAssertLessThanOrEqual(
            header.frame.maxX, 0, "drawer did not close from a left swipe"
        )
    }

    // MARK: - Helpers

    /// Launch, open the history drawer via the toolbar button, and return the
    /// drawer's list.
    private func launchAndOpenDrawer() -> (app: XCUIApplication, list: XCUIElement) {
        let app = XCUIApplication()
        app.launch()

        let history = app.buttons["Chat history"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), "hamburger button not found")
        history.tap()

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "history list not found")
        return (app, list)
    }

    /// The seeded conversation rows ("Test conversation N").
    private func seededRows(in list: XCUIElement) -> XCUIElementQuery {
        list.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Test conversation'"))
    }

    /// Swipe up on the list and report whether the visible content actually
    /// moved. Several attempts, mirroring a user repeatedly trying.
    private func attemptScroll(list: XCUIElement, label: String) -> Bool {
        let rows = seededRows(in: list)
        guard rows.firstMatch.waitForExistence(timeout: 3) else {
            print("[uitest] \(label): no seeded conversation rows visible")
            return false
        }
        for attempt in 1...4 {
            let before = rows.firstMatch.frame
            let beforeLabel = rows.firstMatch.label
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 0.6)
            let after = rows.firstMatch.frame
            let afterLabel = rows.firstMatch.label
            let moved = abs(after.minY - before.minY) > 20 || beforeLabel != afterLabel
            print(
                "[uitest] \(label) attempt \(attempt): '\(beforeLabel)'@\(Int(before.minY))"
                    + " → '\(afterLabel)'@\(Int(after.minY)) moved=\(moved)"
            )
            if moved { return true }
        }
        return false
    }
}
