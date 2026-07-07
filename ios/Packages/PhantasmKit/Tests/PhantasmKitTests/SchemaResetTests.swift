import GRDB
import XCTest
@testable import PhantasmKit

/// The pre-release schema reset in `AppDatabase.open(at:)`: a store whose
/// applied migrations supersede the collapsed single-migration lineage is
/// dev data and gets recreated; current stores open untouched.
final class SchemaResetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("phantasm.sqlite") }

    func testDevLineageStoreIsResetToCurrentSchema() throws {
        // Simulate a store written by a pre-collapse dev build: applied
        // migration identifiers this build's migrator has never heard of.
        do {
            var old = DatabaseMigrator()
            old.registerMigration("v1") { db in
                try db.create(table: "conversation") { t in
                    t.primaryKey("id", .blob).notNull()
                }
            }
            old.registerMigration("v2_per_chat_tools") { _ in }
            let pool = try DatabasePool(path: storeURL.path)
            try old.migrate(pool)
            try pool.close()
        }

        let db = try AppDatabase.open(at: storeURL)
        // Fresh, current-schema store: the old lineage's table shape is gone.
        let columns = try db.reader.read { db in
            try db.columns(in: "message").map(\.name)
        }
        XCTAssertTrue(columns.contains("searchText"))
    }

    func testCurrentStoreReopensWithDataIntact() async throws {
        let convo = Conversation(title: "Keep me")
        do {
            let db = try AppDatabase.open(at: storeURL)
            try await db.insertConversation(convo)
        }
        let reopened = try AppDatabase.open(at: storeURL)
        let fetched = try await reopened.reader.read { db in
            try Conversation.fetchOne(db, key: convo.id)
        }
        XCTAssertEqual(fetched?.title, "Keep me")
    }
}
