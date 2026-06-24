import XCTest
@testable import PhantasmKit

final class GreetingPromptsTests: XCTestCase {
    func testHasAmpleDistinctPhrases() {
        XCTAssertGreaterThanOrEqual(GreetingPrompts.all.count, 30)
        XCTAssertEqual(Set(GreetingPrompts.all).count, GreetingPrompts.all.count, "phrases should be unique")
        XCTAssertFalse(GreetingPrompts.all.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func testRandomReturnsAMemberOfTheList() {
        for _ in 0..<200 {
            XCTAssertTrue(GreetingPrompts.all.contains(GreetingPrompts.random()))
        }
    }

    func testSeededGeneratorIsDeterministic() {
        var g1 = SeededGenerator(seed: 42)
        var g2 = SeededGenerator(seed: 42)
        XCTAssertEqual(GreetingPrompts.random(using: &g1), GreetingPrompts.random(using: &g2))
    }
}

/// Tiny deterministic RNG for reproducible selection in tests.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
