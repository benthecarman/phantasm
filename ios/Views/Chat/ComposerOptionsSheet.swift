import PhantasmKit
import PhotosUI
import SwiftUI
import UIKit

/// The composer's "+" sheet: every per-turn selector in one place — attachments
/// (camera / photos / files), the server-tool toggles (web search, image
/// generation), and the model picker. Rendered as a custom list (not a system
/// `Menu`) so unavailable options can be shown explicitly disabled with their
/// own colors and a reason, instead of the near-invisible system dimming.
struct ComposerOptionsSheet: View {
    @Binding var attachments: [PendingAttachment]
    /// Whether the selected model can accept images (vision). Gates camera + photos.
    let allowsImageAttachments: Bool
    /// Whether the backend advertises each server tool (spec §2.1). Most tools
    /// also require the model to drive function calls (`modelSupportsTools`);
    /// image generation is server-resolved and stays available for every model
    /// when the backend advertises it.
    let supportsWebSearch: Bool
    let supportsImageGeneration: Bool
    /// Whether the backend forwards app-hosted tools (i.e. it's an orchestrator).
    /// Like the server-tool flags, combined with `modelSupportsTools` to decide if
    /// the Location / Health rows are usable.
    let supportsLocation: Bool
    let supportsHealth: Bool
    let supportsCalendar: Bool
    let modelSupportsTools: Bool
    /// Whether the backend exposes the app's Thinking control at all. Non-
    /// Phantasm backends hide the row completely.
    let showsThinkingToggle: Bool
    /// Whether the selected model can produce reasoning output. When false the
    /// Thinking row renders disabled + pinned off rather than hidden.
    let modelSupportsThinking: Bool
    let webSearchEnabled: Binding<Bool>
    let imageGenerationEnabled: Binding<Bool>
    let locationEnabled: Binding<Bool>
    let healthEnabled: Binding<Bool>
    let calendarEnabled: Binding<Bool>
    /// Research modes the backend advertises (e.g. Deep Research), already gated on
    /// their needed tools being usable. Empty ⇒ the Research section is hidden.
    let availableModes: [Capabilities.Mode]
    /// The per-message research mode selection (nil = ordinary turn). Selecting a
    /// mode reaches the wire only as a `<base>:<mode>` model-id suffix at send time.
    let modeID: Binding<String?>
    /// Advertised `reasoning_efforts` for the selected model.
    let reasoningEfforts: [String]
    /// Whether the backend should be allowed to emit thinking/reasoning deltas.
    let thinkingEnabled: Binding<Bool>
    /// Explicit effort selection for models that expose more than on/off.
    let selectedReasoningEffort: Binding<String>

    @Environment(\.dismiss) private var dismiss
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if cameraAvailable {
                        attachmentRow(
                            "Take Photo",
                            systemImage: "camera",
                            enabled: allowsImageAttachments,
                            disabledReason: "Model can't see images"
                        ) { showCamera = true }
                    }
                    attachmentRow(
                        "Photos",
                        systemImage: "photo",
                        enabled: allowsImageAttachments,
                        disabledReason: "Model can't see images"
                    ) { showPhotoPicker = true }
                    attachmentRow(
                        "Files",
                        systemImage: "doc",
                        enabled: true,
                        disabledReason: ""
                    ) { showFileImporter = true }
                }

                if showsThinkingToggle {
                    Section("Response") {
                        reasoningEffortRow
                    }
                }

                Section("Tools") {
                    toolRow(
                        "Web access",
                        systemImage: "globe",
                        backendSupports: supportsWebSearch,
                        isOn: webSearchEnabled
                    )
                    toolRow(
                        "Image generation",
                        systemImage: "wand.and.stars",
                        backendSupports: supportsImageGeneration,
                        requiresModelTools: false,
                        isOn: imageGenerationEnabled
                    )
                    toolRow(
                        "Location",
                        systemImage: "location",
                        backendSupports: supportsLocation,
                        isOn: locationEnabled
                    )
                    toolRow(
                        "Health",
                        systemImage: "heart",
                        backendSupports: supportsHealth,
                        isOn: healthEnabled
                    )
                    toolRow(
                        "Calendar",
                        systemImage: "calendar",
                        backendSupports: supportsCalendar,
                        isOn: calendarEnabled
                    )
                }

                if !availableModes.isEmpty {
                    Section {
                        researchRows
                    } header: {
                        Text("Research")
                    } footer: {
                        Text(
                            "Breaks your question into parts, searches the web across "
                                + "several rounds, and writes a cited answer. Much slower "
                                + "than a normal reply."
                        )
                    }
                }
            }
            .navigationTitle("Add to message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 6,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: AttachmentLoader.importableTypes,
            allowsMultipleSelection: true
        ) { result in loadFiles(result) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let attachment = AttachmentLoader.image(from: image) {
                    attachments.append(attachment)
                    Haptics.notify(.success)
                    dismiss()
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Rows

    /// An attachment action. When disabled it stays listed (discoverable) but is
    /// dimmed with an explicit reason — a custom row, so the colors actually take.
    private func attachmentRow(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        disabledReason: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                icon(systemImage, tint: enabled ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    if !enabled, !disabledReason.isEmpty {
                        Text(disabledReason)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }

    /// A server-tool toggle. Most tools need both the backend to advertise them
    /// and a model that can drive tools; image generation opts out because the
    /// server-side tool loop can resolve it for any selected model.
    private func toolRow(
        _ title: String,
        systemImage: String,
        backendSupports: Bool,
        requiresModelTools: Bool = true,
        isOn: Binding<Bool>
    ) -> some View {
        let available = backendSupports && (!requiresModelTools || modelSupportsTools)
        let reason: String? =
            !backendSupports ? "Not supported by this server"
            : requiresModelTools && !modelSupportsTools ? "This model can't use tools"
            : nil
        return HStack(spacing: 12) {
            icon(systemImage, tint: available ? .accentColor : .secondary)
            Toggle(isOn: available ? feedbackBinding(isOn) : .constant(false)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(available ? Color.primary : Color.secondary)
                    if let reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(!available)
        }
    }

    /// Research-mode selector. A single advertised mode renders as one toggle that
    /// maps to that mode id; multiple modes render as mutually-exclusive rows with
    /// an "Off" option. Disabled (and pinned off) when the model can't drive tools,
    /// since every research mode runs a server-side tool loop.
    @ViewBuilder
    private var researchRows: some View {
        if availableModes.count == 1, let mode = availableModes.first {
            researchToggleRow(mode)
        } else {
            researchSelectRow(id: nil, label: "Off")
            ForEach(availableModes) { mode in
                researchSelectRow(id: mode.id, label: mode.label)
            }
        }
    }

    private func researchToggleRow(_ mode: Capabilities.Mode) -> some View {
        let available = modelSupportsTools
        let binding = Binding(
            get: { modeID.wrappedValue == mode.id },
            set: { modeID.wrappedValue = $0 ? mode.id : nil }
        )
        return HStack(spacing: 12) {
            icon(Self.researchIcon(for: mode.id), tint: available ? .accentColor : .secondary)
            Toggle(isOn: available ? feedbackBinding(binding) : .constant(false)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.label)
                        .foregroundStyle(available ? Color.primary : Color.secondary)
                    if !available {
                        Text("This model can't use tools")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(!available)
        }
    }

    private func researchSelectRow(id: String?, label: String) -> some View {
        let available = modelSupportsTools || id == nil
        let selected = modeID.wrappedValue == id
        return Button {
            if !selected { Haptics.selection() }
            modeID.wrappedValue = id
        } label: {
            HStack(spacing: 12) {
                icon(
                    id == nil ? "slash.circle" : Self.researchIcon(for: id),
                    tint: available ? .accentColor : .secondary
                )
                Text(label)
                    .foregroundStyle(available ? Color.primary : Color.secondary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(!available)
    }

    /// Response reasoning control. Two advertised efforts render as the existing
    /// on/off Thinking toggle; larger effort lists render as a menu picker.
    @ViewBuilder
    private var reasoningEffortRow: some View {
        if reasoningEfforts.count > 2 {
            reasoningEffortPickerRow
        } else {
            reasoningToggleRow
        }
    }

    private var reasoningToggleRow: some View {
        HStack(spacing: 12) {
            icon("brain.head.profile", tint: modelSupportsThinking ? .accentColor : .secondary)
            Toggle(isOn: modelSupportsThinking ? feedbackBinding(thinkingEnabled) : .constant(false)) {
                reasoningLabel(
                    title: "Thinking",
                    available: modelSupportsThinking,
                    disabledReason: "This model can't think"
                )
            }
            .disabled(!modelSupportsThinking)
        }
    }

    private var reasoningEffortPickerRow: some View {
        HStack(spacing: 12) {
            icon("brain.head.profile", tint: modelSupportsThinking ? .accentColor : .secondary)
            reasoningLabel(
                title: "Thinking",
                available: modelSupportsThinking,
                disabledReason: "This model can't think"
            )
            Spacer()
            Picker("Thinking", selection: effortSelection) {
                ForEach(reasoningEfforts, id: \.self) { effort in
                    Text(Self.reasoningEffortLabel(effort))
                        .tag(effort)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!modelSupportsThinking)
        }
    }

    private func reasoningLabel(
        title: String,
        available: Bool,
        disabledReason: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .foregroundStyle(available ? Color.primary : Color.secondary)
            if !available {
                Text(disabledReason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Distinct SF Symbol per research mode so Deep and Quick read differently
    /// at a glance. Unknown/other modes fall back to a generic search glyph.
    static func researchIcon(for id: String?) -> String {
        switch id.flatMap(Capabilities.Mode.Known.init(rawValue:)) {
        case .deepResearch: return "sparkle.magnifyingglass"
        case .quickResearch: return "magnifyingglass"
        case nil: return "text.magnifyingglass"
        }
    }

    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 18))
            .frame(width: 28)
            .foregroundStyle(tint)
    }

    private func feedbackBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if binding.wrappedValue != newValue { Haptics.selection() }
                binding.wrappedValue = newValue
            }
        )
    }

    private var effortSelection: Binding<String> {
        Binding(
            get: {
                reasoningEfforts.contains(selectedReasoningEffort.wrappedValue)
                    ? selectedReasoningEffort.wrappedValue
                    : reasoningEfforts.first ?? ReasoningEffort.enabledDefault
            },
            set: { newValue in
                if selectedReasoningEffort.wrappedValue != newValue { Haptics.selection() }
                selectedReasoningEffort.wrappedValue = newValue
            }
        )
    }

    static func reasoningEffortLabel(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none": return "Off"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default:
            return effort
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    // MARK: Loading

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var loaded: [PendingAttachment] = []
            for item in items {
                if let attachment = await AttachmentLoader.image(from: item) {
                    loaded.append(attachment)
                }
            }
            await MainActor.run {
                attachments.append(contentsOf: loaded)
                if !loaded.isEmpty { Haptics.notify(.success) }
                photoItems = []
                dismiss()
            }
        }
    }

    private func loadFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        Task {
            var loaded: [PendingAttachment] = []
            for url in urls {
                if let attachment = await AttachmentLoader.file(at: url) {
                    loaded.append(attachment)
                }
            }
            guard !loaded.isEmpty else { return }
            attachments.append(contentsOf: loaded)
            Haptics.notify(.success)
            dismiss()
        }
    }
}

/// Model selector presented as a sheet (matching the "+" options sheet) rather
/// than a system dropdown. Each row shows the model's detected capabilities
/// (vision / tools); selecting a model applies it and dismisses.
struct ModelPickerSheet: View {
    let models: [String]
    let selection: Binding<String>
    /// Detected capability sets. `nil` ⇒ undetectable for this backend, so the
    /// corresponding badge is omitted (rather than implying the model lacks it).
    let visionModels: Set<String>?
    let toolModels: Set<String>?
    /// Per-model context window sizes. A model absent from the map shows no size
    /// badge (the backend didn't report one).
    let contextLengths: [String: Int]?
    /// The configured default model, badged so it's identifiable in the list.
    let defaultModel: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(models, id: \.self) { model in
                Button {
                    if selection.wrappedValue != model { Haptics.selection() }
                    selection.wrappedValue = model
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model)
                                .foregroundStyle(.primary)
                            capabilityBadges(for: model)
                        }
                        Spacer()
                        if model == selection.wrappedValue {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func capabilityBadges(for model: String) -> some View {
        let isDefault = model == defaultModel
        let isVision = visionModels?.contains(model) == true
        let isTools = toolModels?.contains(model) == true
        let context = contextLengths?[model]
        if isDefault || isVision || isTools || context != nil {
            HStack(spacing: 6) {
                if isDefault { badge("Default", systemImage: "star.fill", tint: .accentColor) }
                if isVision { badge("Vision", systemImage: "eye") }
                if isTools { badge("Tools", systemImage: "wrench.and.screwdriver") }
                if let context {
                    badge(ContextWindow.formatTokens(context), systemImage: "memorychip")
                }
            }
        }
    }

    private func badge(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
