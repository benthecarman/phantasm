import PhantasmKit
import SwiftUI

/// Confirmation UI for `create_calendar_event`. The EventKit write happens only
/// after the user taps Add; Cancel returns a non-fatal tool result to the model.
struct CalendarEventPromptView: View {
    let confirmation: CalendarEventConfirmation
    let onDecision: (Bool) -> Void

    private var draft: CalendarEventDraft { confirmation.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(.tint)
                Text("Add event?")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(draft.title)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                detailRow(systemImage: "clock", text: timeText)
                if let calendar = clean(draft.calendarTitle) {
                    detailRow(systemImage: "calendar", text: calendar)
                }
                if let location = clean(draft.location) {
                    detailRow(systemImage: "mappin.and.ellipse", text: location)
                }
                if let notes = clean(draft.notes) {
                    detailRow(systemImage: "note.text", text: notes)
                }
            }

            HStack {
                Button(role: .cancel) {
                    Haptics.selection()
                    onDecision(false)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Haptics.impact(.medium)
                    onDecision(true)
                } label: {
                    Label("Add", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private var timeText: String {
        if draft.isAllDay {
            let inclusiveEnd = Calendar.current.date(byAdding: .day, value: -1, to: draft.end)
                ?? draft.start
            let end = max(inclusiveEnd, draft.start)
            let startText = Self.shortDate(draft.start)
            let endText = Self.shortDate(end)
            return startText == endText ? "\(startText), all day" : "\(startText)-\(endText), all day"
        }
        if Calendar.current.isDate(draft.start, inSameDayAs: draft.end) {
            return "\(Self.shortDate(draft.start)), \(Self.shortTime(draft.start))-\(Self.shortTime(draft.end))"
        }
        return "\(Self.shortDateTime(draft.start))-\(Self.shortDateTime(draft.end))"
    }

    @ViewBuilder
    private func detailRow(systemImage: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
