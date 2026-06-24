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
    /// completed messages with text or attachments are sent.
    public func wireHistory() -> [WireMessage] {
        orderedMessages
            .filter { $0.isComplete && !($0.content.isEmpty && $0.attachments.isEmpty) }
            .map { WireMessage(role: $0.role, content: $0.wireContent()) }
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

    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    public var attachments: [Attachment]

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
        self.attachments = []
    }

    /// Attachments in stable insertion order.
    public var orderedAttachments: [Attachment] {
        attachments.sorted { $0.createdAt < $1.createdAt }
    }

    /// The wire body for this message. Plain text unless the message carries
    /// attachments; image attachments become `image_url` parts and text files
    /// are inlined as additional text (so non-vision models still get them).
    public func wireContent() -> WireContent {
        let ordered = orderedAttachments
        let images = ordered.filter { $0.kind == AttachmentKind.image.rawValue }
        let files = ordered.filter { $0.kind == AttachmentKind.text.rawValue }
        guard !images.isEmpty || !files.isEmpty else { return .text(content) }

        var textBlocks: [String] = []
        if !content.isEmpty { textBlocks.append(content) }
        for file in files {
            textBlocks.append("Attached file \"\(file.name)\":\n\(file.text)")
        }
        let combinedText = textBlocks.joined(separator: "\n\n")

        guard !images.isEmpty else { return .text(combinedText) }

        var parts: [WirePart] = []
        if !combinedText.isEmpty { parts.append(.text(combinedText)) }
        for image in images {
            let base64 = image.data.base64EncodedString()
            parts.append(.imageURL("data:\(image.mimeType);base64,\(base64)"))
        }
        return .parts(parts)
    }
}

/// Kinds of message attachment. Images ride along as vision input; text files
/// are extracted to plain text on-device and inlined into the prompt.
public enum AttachmentKind: String, Sendable {
    case image
    case text
}

@Model
public final class Attachment {
    @Attribute(.unique) public var id: UUID
    /// `AttachmentKind` raw value.
    public var kind: String
    /// Display label — the source filename, or a synthesized name for photos.
    public var name: String
    /// Image bytes (for `.image`); empty for text files.
    @Attribute(.externalStorage) public var data: Data
    /// MIME type of `data` (for `.image`), e.g. `image/jpeg`.
    public var mimeType: String
    /// Extracted text (for `.text`); empty for images.
    public var text: String
    public var createdAt: Date
    public var message: Message?

    public init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        name: String,
        data: Data = Data(),
        mimeType: String = "image/jpeg",
        text: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.name = name
        self.data = data
        self.mimeType = mimeType
        self.text = text
        self.createdAt = createdAt
    }
}

public enum PhantasmSchema {
    /// All persisted model types — pass to `ModelContainer`.
    public static var models: [any PersistentModel.Type] {
        [Conversation.self, Message.self, Attachment.self]
    }
}
