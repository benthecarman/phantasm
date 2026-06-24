import SwiftData
import XCTest
@testable import PhantasmKit

final class CapabilityDecodeTests: XCTestCase {
    func testFullManifestDecodes() throws {
        let json = """
        {"version":"0.1.0","chat":true,"models":["llama3.1","qwen2.5:14b"],
         "tools":{"web_search":true,"image_generation":false},"streaming":"sse"}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.models, ["llama3.1", "qwen2.5:14b"])
        XCTAssertEqual(caps.tools?.webSearch, true)
        XCTAssertEqual(caps.tools?.imageGeneration, false)

        let mode = BackendMode.full(caps)
        XCTAssertTrue(mode.showsTools)
        XCTAssertEqual(mode.models.count, 2)
    }

    func testPlainChatModeHasNoToolsButCarriesModels() {
        let mode = BackendMode.plainChatOnly(models: ["qwen2.5:7b", "bwen:8b"])
        XCTAssertFalse(mode.showsTools)
        XCTAssertEqual(mode.models, ["qwen2.5:7b", "bwen:8b"])
        XCTAssertNil(mode.capabilities)
    }

    func testManifestWithoutToolsBlock() throws {
        let json = #"{"version":"x","chat":true,"models":[],"streaming":"sse"}"#
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertFalse(BackendMode.full(caps).showsTools)
    }
}

final class ErrorMappingTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertNil(AppError.fromStatus(200))
        XCTAssertEqual(AppError.fromStatus(401), .authFailed)
        XCTAssertEqual(AppError.fromStatus(403), .authFailed)
        XCTAssertEqual(AppError.fromStatus(404), .notFound)
        XCTAssertEqual(AppError.fromStatus(500), .modelError("HTTP 500"))
    }

    func testURLErrorMapping() {
        XCTAssertEqual(AppError.from(URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(AppError.from(URLError(.timedOut)), .unreachable)
        XCTAssertEqual(AppError.from(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(AppError.from(CancellationError()), .cancelled)
    }
}

final class Base64ImageExtractorTests: XCTestCase {
    func testExtractsAndReplacesDataURI() {
        let payload = Data("hello".utf8).base64EncodedString()
        let md = "Here: ![generated](data:image/png;base64,\(payload)) done"
        let result = Base64ImageExtractor().extract(md)
        XCTAssertTrue(result.markdown.contains("phantasm-img://0"))
        XCTAssertFalse(result.markdown.contains("base64"))
        XCTAssertEqual(result.images[0], Data("hello".utf8))
    }

    func testLeavesHttpImagesUntouched() {
        let md = "![x](https://example.com/a.png)"
        let result = Base64ImageExtractor().extract(md)
        XCTAssertEqual(result.markdown, md)
        XCTAssertTrue(result.images.isEmpty)
    }

    func testNoImagesIsNoOp() {
        let md = "just **text** and `code`"
        let result = Base64ImageExtractor().extract(md)
        XCTAssertEqual(result.markdown, md)
        XCTAssertTrue(result.images.isEmpty)
    }
}

@MainActor
final class PersistenceTests: XCTestCase {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Conversation.self, Message.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testCascadeDeleteAndWireHistory() throws {
        let ctx = try inMemoryContext()
        let convo = Conversation(title: "T")
        ctx.insert(convo)
        let user = Message(role: "user", content: "hi")
        let assistant = Message(role: "assistant", content: "hello", isComplete: true)
        let streaming = Message(role: "assistant", content: "", isComplete: false)
        user.conversation = convo
        assistant.conversation = convo
        streaming.conversation = convo
        ctx.insert(user)
        ctx.insert(assistant)
        ctx.insert(streaming)
        try ctx.save()

        // wireHistory only includes complete, non-empty messages (XR-2).
        let history = convo.wireHistory()
        XCTAssertEqual(history, [
            WireMessage(role: "user", content: "hi"),
            WireMessage(role: "assistant", content: "hello"),
        ])

        // Deleting the conversation cascades to its messages.
        ctx.delete(convo)
        try ctx.save()
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        XCTAssertTrue(remaining.isEmpty)
    }

    func testBufferThenCommitProducesOneCompleteMessage() throws {
        let ctx = try inMemoryContext()
        let convo = Conversation(title: "T")
        ctx.insert(convo)
        // Simulate streaming: insert empty incomplete, then commit once.
        let msg = Message(role: "assistant", content: "", isComplete: false)
        msg.conversation = convo
        ctx.insert(msg)
        try ctx.save()
        msg.content = "final answer"
        msg.isComplete = true
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.content, "final answer")
        XCTAssertEqual(all.first?.isComplete, true)
    }
}
