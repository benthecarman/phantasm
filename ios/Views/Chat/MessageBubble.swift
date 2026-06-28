import PhantasmKit
import SwiftUI

/// A single persisted message (paired with its ordered attachments). User
/// messages render as plain text in a tinted bubble; assistant messages render
/// markdown (with images + code copy).
struct MessageBubble: View {
    let message: ChatMessage
    /// Whether this row is currently being edited (drives the inline editor).
    var isEditing = false
    /// Whether the "Edit" action is offered (user messages, no turn in flight).
    var canEdit = false
    /// Whether the "Resend" action is offered (user messages, no turn in flight).
    var canResend = false
    /// Whether the "Regenerate" action is offered (assistant messages, idle).
    var canRegenerate = false
    /// The shared draft text while editing (only the editing row reads it).
    var editText: Binding<String> = .constant("")
    var onBeginEdit: () -> Void = {}
    var onSubmitEdit: () -> Void = {}
    var onCancelEdit: () -> Void = {}
    var onResend: () -> Void = {}
    var onRegenerate: () -> Void = {}
    /// Tapping an image (attached or generated) opens the full-screen viewer,
    /// reporting the source message, the image's ordinal within it, and bytes.
    var onTapImage: (UUID, Int, UIImage) -> Void = { _, _, _ in }

    @Environment(AppEnvironment.self) private var env
    @FocusState private var editorFocused: Bool

    private var isUser: Bool { message.message.role == "user" }
    private var content: String { message.message.content }

    /// Locally-cached server images for this message, keyed by file id, so
    /// references render from local bytes once fetched.
    private var cachedImages: [String: ServerImageRef.CachedImage] {
        var out: [String: ServerImageRef.CachedImage] = [:]
        for a in message.attachments where a.kind == AttachmentKind.remoteImage.rawValue {
            out[a.name] = ServerImageRef.CachedImage(data: a.data, mime: a.mimeType)
        }
        return out
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            if isUser {
                if isEditing {
                    editor
                } else {
                    userBubble
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !message.message.reasoning.isEmpty {
                        ThinkingDisclosure(text: message.message.reasoning)
                    }
                    if !content.isEmpty {
                        MarkdownMessageView(text: content, cachedImages: cachedImages) { index, image in
                            onTapImage(message.message.id, index, image)
                        }
                    }
                    footer
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = content
            Haptics.notify(.success)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    /// Read this assistant message aloud on-device (TTS), or stop if it's already
    /// speaking. Markdown/images are reduced to plain prose before synthesis.
    private var speakButton: some View {
        let isSpeaking = env.speechSynthesizer.speakingMessageID == message.message.id
        return Button {
            Haptics.selection()
            env.speechSynthesizer.toggle(content, messageID: message.message.id)
        } label: {
            if isSpeaking {
                Label("Stop", systemImage: "stop.fill")
            } else {
                Label("Speak", systemImage: "speaker.wave.2")
            }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                MessageAttachmentsView(attachments: message.attachments) { index, image in
                    onTapImage(message.message.id, index, image)
                }
            }
            if !content.isEmpty {
                Text(content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            timestamp
            if !content.isEmpty {
                actionMenu
            }
        }
    }

    private var actionMenu: some View {
        Menu {
            copyButton
            if isUser {
                if canEdit {
                    Button(action: onBeginEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                if canResend {
                    Button(action: onResend) {
                        Label("Resend", systemImage: "arrow.clockwise")
                    }
                }
            } else {
                speakButton
                if canRegenerate {
                    Button(action: onRegenerate) {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message actions")
    }

    private var timestamp: some View {
        Text(message.message.createdAt, format: .dateTime.hour().minute())
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityLabel(
                Text(
                    message.message.createdAt,
                    format: .dateTime.weekday(.wide).month(.wide).day().year().hour().minute()
                )
            )
    }

    /// Inline editor shown in place of a user bubble: edit the text and re-ask,
    /// or cancel back to the original. Attachments ride along unchanged.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !message.attachments.isEmpty {
                MessageAttachmentsView(attachments: message.attachments)
            }
            TextField("Message", text: editText, axis: .vertical)
                .lineLimit(1...10)
                .focused($editorFocused)
                .padding(10)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancelEdit)
                    .buttonStyle(.bordered)
                Button("Send", action: onSubmitEdit)
                    .buttonStyle(.borderedProminent)
                    .disabled(editText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.callout)
            .controlSize(.small)
            timestamp
        }
        .onAppear { editorFocused = true }
    }
}

/// The in-progress assistant turn: live markdown while streaming, plus the
/// current `x_status` line (FR-A8).
struct StreamingBubble: View {
    let text: String
    let reasoning: String
    let status: String?
    let progress: Double?
    /// When the turn began — used only to seed the loader's verb (deterministic
    /// per turn). The preview shows no timestamp; that appears once the turn is
    /// complete and the bubble becomes a persisted `MessageBubble`. VM-owned so
    /// it's fresh each turn rather than reused by SwiftUI for the recycled bubble.
    let startedAt: Date

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if let status, !status.isEmpty {
                    StatusPill(text: status, isAnimated: true, progress: progress)
                }
                if !reasoning.isEmpty {
                    ThinkingDisclosure(text: reasoning)
                }
                // Show the loader until there's something to render. Gate on an
                // empty-or-nil status (not just nil) so a blank `x_status` value
                // doesn't leave the bubble with no indicator at all.
                if text.isEmpty && reasoning.isEmpty && (status?.isEmpty ?? true) {
                    ConjuringLoader(seed: startedAt)
                } else if !text.isEmpty {
                    MarkdownMessageView(text: text)
                }
            }
            Spacer(minLength: 40)
        }
    }
}

struct ThinkingDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label("Thinking", systemImage: "brain.head.profile")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
