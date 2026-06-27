import PhantasmKit
import SwiftUI

/// The pending `ask_user_input` prompt rendered above the composer. A form may
/// carry several questions; they're presented **one at a time** as a stepper.
/// A single-select question advances (or sends, on the last step) the moment the
/// user taps an option; multi-select and rank questions need an explicit Next /
/// Send since their answer isn't a single tap. Back revisits earlier answers. The
/// user can always ignore this and free-type in the composer instead — the view
/// model routes that to the same answer path.
struct ChoicePromptView: View {
    let choice: MultipleChoice
    let onAnswer: (String) -> Void

    /// Per-question chosen option indices in tap order, keyed by question index.
    /// Order is meaningful for rank questions and harmless elsewhere.
    @State private var selections: [Int: [Int]] = [:]
    /// The question currently on screen.
    @State private var index: Int = 0

    private var current: MultipleChoice.Question { choice.questions[index] }
    private var isLast: Bool { index == choice.questions.count - 1 }
    private var hasMany: Bool { choice.questions.count > 1 }
    private var currentComplete: Bool { isComplete(qIndex: index, question: current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasMany { progressHeader }

            questionSection(qIndex: index, question: current)
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            footer
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private var progressHeader: some View {
        HStack {
            Text("Question \(index + 1) of \(choice.questions.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 5) {
                ForEach(choice.questions.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.accentColor : Color.primary.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        // Single-select advances on tap, so it needs no Next button; show one for
        // multi-select / rank. Back is available once past the first question.
        let needsAdvanceButton = current.type != .singleSelect
        if index > 0 || needsAdvanceButton {
            HStack {
                if index > 0 {
                    Button {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.25)) { index -= 1 }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if needsAdvanceButton {
                    Button(isLast ? "Send" : "Next") { advanceOrSend() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!currentComplete)
                }
            }
        }
    }

    @ViewBuilder
    private func questionSection(qIndex: Int, question: MultipleChoice.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.prompt)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if question.type == .rankPriorities {
                Text("Tap in priority order")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(question.options.enumerated()), id: \.offset) { oIndex, option in
                optionButton(qIndex: qIndex, oIndex: oIndex, option: option, question: question)
            }
        }
    }

    @ViewBuilder
    private func optionButton(
        qIndex: Int, oIndex: Int, option: String, question: MultipleChoice.Question
    ) -> some View {
        let rank = selections[qIndex]?.firstIndex(of: oIndex)
        let isSelected = rank != nil
        Button {
            tap(oIndex: oIndex, question: question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: indicator(type: question.type, rank: rank))
                    .foregroundStyle(.tint)
                Text(option)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.10),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// The leading glyph for an option given its question type and current rank
    /// (nil = unselected). Rank questions show a numbered badge.
    private func indicator(type: MultipleChoice.QuestionType, rank: Int?) -> String {
        switch type {
        case .singleSelect:
            return rank != nil ? "largecircle.fill.circle" : "circle"
        case .multiSelect:
            return rank != nil ? "checkmark.square.fill" : "square"
        case .rankPriorities:
            guard let rank else { return "circle" }
            let n = rank + 1
            return n <= 50 ? "\(n).circle.fill" : "circle.fill"
        }
    }

    private func tap(oIndex: Int, question: MultipleChoice.Question) {
        select(qIndex: index, oIndex: oIndex, type: question.type)
        // A single choice is a complete answer — move on immediately.
        if question.type == .singleSelect {
            if isLast {
                Haptics.impact(.medium)
            } else {
                Haptics.selection()
            }
            advanceOrSend(feedback: false)
        } else {
            Haptics.selection()
        }
    }

    private func advanceOrSend(feedback: Bool = true) {
        if feedback {
            if isLast {
                Haptics.impact(.medium)
            } else {
                Haptics.selection()
            }
        }
        if isLast {
            send()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { index += 1 }
        }
    }

    private func isComplete(qIndex: Int, question: MultipleChoice.Question) -> Bool {
        let picks = selections[qIndex] ?? []
        switch question.type {
        case .singleSelect, .multiSelect:
            return !picks.isEmpty
        case .rankPriorities:
            return picks.count == question.options.count
        }
    }

    private func select(qIndex: Int, oIndex: Int, type: MultipleChoice.QuestionType) {
        var picks = selections[qIndex] ?? []
        switch type {
        case .singleSelect:
            picks = [oIndex]
        case .multiSelect, .rankPriorities:
            if let pos = picks.firstIndex(of: oIndex) {
                picks.remove(at: pos)
            } else {
                picks.append(oIndex)
            }
        }
        selections[qIndex] = picks
    }

    private func send() {
        guard choice.questions.indices.allSatisfy({ isComplete(qIndex: $0, question: choice.questions[$0]) })
        else { return }
        let parts = choice.questions.enumerated().map { qIndex, question -> String in
            "Q: \(question.prompt)\nA: \(answerText(qIndex: qIndex, question: question))"
        }
        onAnswer(parts.joined(separator: "\n\n"))
    }

    private func answerText(qIndex: Int, question: MultipleChoice.Question) -> String {
        let picks = selections[qIndex] ?? []
        switch question.type {
        case .singleSelect, .multiSelect:
            return picks.map { question.options[$0] }.joined(separator: ", ")
        case .rankPriorities:
            return picks.enumerated()
                .map { "\($0.offset + 1). \(question.options[$0.element])" }
                .joined(separator: ", ")
        }
    }
}
