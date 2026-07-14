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
    /// Persisted content with extracted inline images restored to data URIs
    /// (memoized), so the markdown pipeline sees what the model produced.
    private var content: String {
        InlineImageRef.restore(message.message.content, images: message.inlineImages)
    }

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
                        ThinkingDisclosure(
                            text: message.message.reasoning,
                            duration: message.message.reasoningDuration
                        )
                    }
                    // A `render_chart` row draws its chart(s) here; an invalid spec
                    // shows a plain-text note instead of rendering something broken.
                    ForEach(Array(message.chartRenders.enumerated()), id: \.offset) { _, render in
                        switch render {
                        case let .success(spec):
                            ChartView(spec: spec)
                        case let .failure(error):
                            chartFallback(error)
                        }
                    }
                    if !message.message.content.isEmpty {
                        MarkdownMessageView(
                            text: message.message.content,
                            storedImages: message.inlineImages,
                            cachedImages: cachedImages,
                            trustedImageBase: env.activeProfile?.baseURL
                        ) { index, image in
                            onTapImage(message.message.id, index, image)
                        }
                    }
                    footer
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    /// Shown in place of a chart when the model's `render_chart` data can't be
    /// drawn (empty/oversized/non-finite). Clear and non-crashing; the model also
    /// receives the reason via the tool result and usually answers in prose next.
    private func chartFallback(_ error: ChartSpec.ValidationError) -> some View {
        Label(error.message, systemImage: "chart.bar.xaxis")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
    let reasoningDuration: TimeInterval?
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
                    // Reasoning is "live" until the answer starts streaming; after
                    // that the trace is complete and the chip settles.
                    ThinkingDisclosure(
                        text: reasoning,
                        duration: reasoningDuration,
                        isStreaming: text.isEmpty,
                        allowsTextSelection: false
                    )
                }
                // Show the loader until there's something to render. Gate on an
                // empty-or-nil status (not just nil) so a blank `x_status` value
                // doesn't leave the bubble with no indicator at all.
                if text.isEmpty && reasoning.isEmpty && (status?.isEmpty ?? true) {
                    ConjuringLoader(seed: startedAt)
                } else if !text.isEmpty {
                    MarkdownMessageView(text: text, isStreaming: true)
                }
            }
            Spacer(minLength: 40)
        }
    }
}

/// The model's reasoning trace, collapsed behind a compact tappable chip. The
/// chip hugs its label (no full-width bar); while reasoning tokens are still
/// arriving it shimmers like the app's other activity indicators.
struct ThinkingDisclosure: View {
    let text: String
    /// Elapsed reasoning time once thinking has completed. Nil keeps the legacy
    /// label for older messages whose duration was not recorded.
    var duration: TimeInterval? = nil
    /// Whether reasoning tokens are still streaming in — drives the shimmer.
    var isStreaming = false
    /// Live preview text is rebuilt throughout generation; selectable text makes
    /// that path significantly heavier, so only committed reasoning enables it.
    var allowsTextSelection = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var sweep = false
    @State private var pulse = false

    private var shouldAnimate: Bool { isStreaming && !reduceMotion }

    private var label: String {
        if isStreaming { return "Thinking…" }
        guard let duration else { return "Thought" }
        return "Thought for \(ReasoningDuration.format(duration))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityHint(isExpanded ? "Collapses the reasoning" : "Expands the reasoning")

            if isExpanded {
                reasoningBody
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear(perform: startAnimationIfNeeded)
        .onChange(of: shouldAnimate) { _, _ in startAnimationIfNeeded() }
    }

    private var chip: some View {
        chipLabel(dimmed: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay {
                if shouldAnimate {
                    chipLabel(dimmed: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .mask(shimmerBand)
                }
            }
            .contentShape(Capsule())
    }

    /// The chip content twice: the resting secondary version, and a brighter
    /// copy masked to the moving band so a glint travels across the glyphs.
    private func chipLabel(dimmed: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "brain.head.profile")
                .scaleEffect(shouldAnimate ? (pulse ? 1.08 : 0.94) : 1)
            Text(label)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(isExpanded ? -180 : 0))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    private var shimmerBand: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, .white, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 50)
            .offset(x: sweep ? proxy.size.width + 25 : -75)
        }
    }

    @ViewBuilder
    private var reasoningBody: some View {
        let body = Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 2)
            }
            .padding(.top, 8)
            .padding(.leading, 8)

        if allowsTextSelection {
            body.textSelection(.enabled)
        } else {
            body
        }
    }

    private func startAnimationIfNeeded() {
        guard shouldAnimate else {
            sweep = false
            pulse = false
            return
        }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            sweep = true
        }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

#Preview("Thinking") {
    VStack(alignment: .leading, spacing: 16) {
        ThinkingDisclosure(
            text: "The user is asking about X. Let me consider the trade-offs before answering.",
            isStreaming: true,
            allowsTextSelection: false
        )
        ThinkingDisclosure(
            text: "The user is asking about X. Let me consider the trade-offs before answering."
        )
    }
    .padding(24)
}
