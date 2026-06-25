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
    /// Whether the "Regenerate" action is offered (assistant messages, idle).
    var canRegenerate = false
    /// The shared draft text while editing (only the editing row reads it).
    var editText: Binding<String> = .constant("")
    var onBeginEdit: () -> Void = {}
    var onSubmitEdit: () -> Void = {}
    var onCancelEdit: () -> Void = {}
    var onRegenerate: () -> Void = {}

    @FocusState private var editorFocused: Bool

    private var isUser: Bool { message.message.role == "user" }
    private var content: String { message.message.content }

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
                MarkdownMessageView(text: content)
                    .contextMenu {
                        copyButton
                        if canRegenerate {
                            Button(action: onRegenerate) {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                            }
                        }
                    }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = content
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                MessageAttachmentsView(attachments: message.attachments)
            }
            if !content.isEmpty {
                Text(content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .contextMenu {
                        copyButton
                        if canEdit {
                            Button(action: onBeginEdit) {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                    }
            }
        }
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
        }
        .onAppear { editorFocused = true }
    }
}

/// The in-progress assistant turn: live markdown while streaming, plus the
/// current `x_status` line (FR-A8).
struct StreamingBubble: View {
    let text: String
    let status: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if let status, !status.isEmpty {
                    StatusPill(text: status)
                }
                if text.isEmpty && (status == nil) {
                    ProgressView()
                } else if !text.isEmpty {
                    MarkdownMessageView(text: text)
                }
            }
            Spacer(minLength: 40)
        }
    }
}
