import XCTest
@testable import PhantasmKit

/// Covers the per-backend model cache that keeps the model picker populated
/// instantly on launch (before a fresh capability probe completes).
final class ProfileStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: ProfileStore!

    override func setUp() {
        super.setUp()
        // An isolated, in-memory-ish suite so tests never touch the real domain.
        defaults = UserDefaults(suiteName: "phantasm.tests.\(UUID().uuidString)")
        store = ProfileStore(defaults: defaults)
    }

    func testCachedModelsEmptyByDefault() {
        XCTAssertEqual(store.cachedModels(for: UUID()), [])
    }

    func testCacheAndReadBackPerProfile() {
        let a = UUID(), b = UUID()
        store.cacheModels(["llama3.1", "qwen2.5"], for: a)
        store.cacheModels(["mistral"], for: b)
        XCTAssertEqual(store.cachedModels(for: a), ["llama3.1", "qwen2.5"])
        XCTAssertEqual(store.cachedModels(for: b), ["mistral"])
    }

    func testCacheOverwritesPreviousList() {
        let id = UUID()
        store.cacheModels(["old"], for: id)
        store.cacheModels(["new1", "new2"], for: id)
        XCTAssertEqual(store.cachedModels(for: id), ["new1", "new2"])
    }

    func testClearCachedModelsRemovesOnlyThatProfile() {
        let a = UUID(), b = UUID()
        store.cacheModels(["x"], for: a)
        store.cacheModels(["y"], for: b)
        store.clearCachedModels(for: a)
        XCTAssertEqual(store.cachedModels(for: a), [])
        XCTAssertEqual(store.cachedModels(for: b), ["y"])
    }

    func testCachePersistsAcrossStoreInstances() {
        let id = UUID()
        store.cacheModels(["persisted"], for: id)
        // A fresh store over the same defaults simulates a relaunch.
        let reopened = ProfileStore(defaults: defaults)
        XCTAssertEqual(reopened.cachedModels(for: id), ["persisted"])
    }

    // MARK: - Profile list load safety

    func testFreshInstallLoadsEmptyAndComplete() {
        let loaded = store.load()
        XCTAssertTrue(loaded.profiles.isEmpty)
        XCTAssertTrue(loaded.isComplete)
    }

    func testSaveAndLoadRoundTripIsComplete() {
        let profile = BackendProfile(name: "Home", baseURLString: "https://backend.example")
        store.save([profile])
        let loaded = store.load()
        XCTAssertEqual(loaded.profiles, [profile])
        XCTAssertTrue(loaded.isComplete)
    }

    func testUndecodableBlobLoadsEmptyButIncomplete() {
        // `isComplete == false` is the signal that gates the launch-time
        // keychain reconciliation — a failed decode must never read as
        // "no profiles exist, delete all tokens".
        defaults.set(Data("not json".utf8), forKey: "phantasm.profiles")
        let loaded = store.load()
        XCTAssertTrue(loaded.profiles.isEmpty)
        XCTAssertFalse(loaded.isComplete)
    }

    func testOneCorruptProfileIsDroppedWithoutLosingTheRest() throws {
        let good = BackendProfile(name: "Good", baseURLString: "https://ok.example")
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        // Second element is missing required keys — undecodable as a profile.
        let blob = "[\(goodJSON), {\"junk\": true}]"
        defaults.set(Data(blob.utf8), forKey: "phantasm.profiles")
        let loaded = store.load()
        XCTAssertEqual(loaded.profiles, [good])
        XCTAssertFalse(loaded.isComplete)
    }
}

final class ModelPreferenceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: ModelPreferenceStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "phantasm.tests.\(UUID().uuidString)")
        store = ModelPreferenceStore(defaults: defaults)
    }

    func testThinkingPreferenceStoresExplicitValuesPerProfileAndModel() {
        let a = UUID(), b = UUID()

        XCTAssertFalse(store.thinkingEnabled(for: "qwen3", profileID: a))

        store.setThinkingEnabled(true, for: "qwen3", profileID: a)

        XCTAssertTrue(store.thinkingEnabled(for: "qwen3", profileID: a))
        XCTAssertFalse(store.thinkingEnabled(for: "llama", profileID: a))
        XCTAssertFalse(store.thinkingEnabled(for: "qwen3", profileID: b))
    }

    func testThinkingPreferencePersistsAcrossStoreInstances() {
        let id = UUID()
        store.setThinkingEnabled(true, for: "qwen3", profileID: id)

        let reopened = ModelPreferenceStore(defaults: defaults)

        XCTAssertTrue(reopened.thinkingEnabled(for: "qwen3", profileID: id))
    }

    func testClearThinkingPreferencesRemovesOnlyThatProfile() {
        let a = UUID(), b = UUID()
        store.setThinkingEnabled(true, for: "qwen3", profileID: a)
        store.setThinkingEnabled(true, for: "qwen3", profileID: b)

        store.clearThinkingPreferences(for: a)

        XCTAssertFalse(store.thinkingEnabled(for: "qwen3", profileID: a))
        XCTAssertTrue(store.thinkingEnabled(for: "qwen3", profileID: b))
    }
}
