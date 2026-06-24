import Foundation
import SwiftData

/// On-device conversation history (NFR-A3). No cloud dependency in MVP.

@Model
public final class Conversation {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var modelID: String?
    public var profileID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message]

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = .now,
        modelID: String? = nil,
        profileID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.modelID = modelID
        self.profileID = profileID
        self.messages = []
    }

    /// Messages in chronological order.
    public var orderedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Full history mapped to the wire format (stateless server, XR-2). Only
    /// completed messages are sent.
    public func wireHistory() -> [WireMessage] {
        orderedMessages
            .filter { $0.isComplete && !$0.content.isEmpty }
            .map { WireMessage(role: $0.role, content: $0.content) }
    }
}

@Model
public final class Message {
    @Attribute(.unique) public var id: UUID
    public var role: String
    public var content: String
    public var createdAt: Date
    /// `false` while streaming; flipped to `true` once the turn finishes.
    public var isComplete: Bool
    public var conversation: Conversation?

    public init(
        id: UUID = UUID(),
        role: String,
        content: String,
        createdAt: Date = .now,
        isComplete: Bool = true
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isComplete = isComplete
    }
}

public enum PhantasmSchema {
    /// All persisted model types — pass to `ModelContainer`.
    public static var models: [any PersistentModel.Type] {
        [Conversation.self, Message.self]
    }
}
