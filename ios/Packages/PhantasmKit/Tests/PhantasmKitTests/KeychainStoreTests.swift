import Foundation
import Security
@testable import PhantasmKit
import XCTest

final class KeychainStoreTests: XCTestCase {
    func testExistingTokenUsesAtomicUpdateWithoutAdd() throws {
        let calls = CallRecorder(updateStatus: errSecSuccess, addStatus: errSecSuccess)
        let store = calls.makeStore()

        try store.setToken("replacement", for: UUID())

        XCTAssertEqual(calls.updateCount, 1)
        XCTAssertEqual(calls.addCount, 0)
    }

    func testMissingTokenFallsBackToAdd() throws {
        let calls = CallRecorder(updateStatus: errSecItemNotFound, addStatus: errSecSuccess)
        let store = calls.makeStore()

        try store.setToken("new token", for: UUID())

        XCTAssertEqual(calls.updateCount, 1)
        XCTAssertEqual(calls.addCount, 1)
    }

    func testFailedUpdateDoesNotAttemptDestructiveReplacement() {
        let failure = errSecInteractionNotAllowed
        let calls = CallRecorder(updateStatus: failure, addStatus: errSecSuccess)
        let store = calls.makeStore()

        XCTAssertThrowsError(try store.setToken("replacement", for: UUID())) { error in
            XCTAssertEqual(error as? KeychainStore.KeychainError, .unhandled(failure))
        }
        XCTAssertEqual(calls.updateCount, 1)
        XCTAssertEqual(calls.addCount, 0)
    }

    func testFailedAddIsPropagated() {
        let failure = errSecNotAvailable
        let calls = CallRecorder(updateStatus: errSecItemNotFound, addStatus: failure)
        let store = calls.makeStore()

        XCTAssertThrowsError(try store.setToken("new token", for: UUID())) { error in
            XCTAssertEqual(error as? KeychainStore.KeychainError, .unhandled(failure))
        }
        XCTAssertEqual(calls.updateCount, 1)
        XCTAssertEqual(calls.addCount, 1)
    }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let updateStatus: OSStatus
    private let addStatus: OSStatus
    private var updates = 0
    private var adds = 0

    init(updateStatus: OSStatus, addStatus: OSStatus) {
        self.updateStatus = updateStatus
        self.addStatus = addStatus
    }

    var updateCount: Int {
        lock.withLock { updates }
    }

    var addCount: Int {
        lock.withLock { adds }
    }

    func makeStore() -> KeychainStore {
        KeychainStore(
            service: "test",
            updateItem: { [self] _, _ in
                lock.withLock { updates += 1 }
                return updateStatus
            },
            addItem: { [self] _ in
                lock.withLock { adds += 1 }
                return addStatus
            }
        )
    }
}
