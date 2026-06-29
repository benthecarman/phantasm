import EventKit
import Foundation
import PhantasmKit

/// EventKit-backed `CalendarProviding` for the app-hosted `get_calendar_events`
/// tool. Lives in the app target (EventKit is kept out of `PhantasmKit` so the
/// package stays host-testable); `CalendarTool` holds this behind the protocol
/// and does the pure parsing + formatting.
///
/// Read-only: it requests full calendar-event access only so it can read events;
/// it never creates, edits, or deletes calendar data.
@MainActor
final class CalendarProvider: CalendarProviding {
    private let store = EKEventStore()

    /// Prompt for full calendar access now, if the user hasn't been asked. Called
    /// when the calendar tool is enabled for a chat so the system sheet appears on
    /// that tap rather than on the model's first call.
    func requestAuthorization() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        store.requestFullAccessToEvents { _, _ in }
    }

    func events(matching query: CalendarEventQuery) async -> Result<[CalendarEvent], CalendarLookupError> {
        switch await ensureFullAccess() {
        case .success:
            break
        case .failure(let error):
            return .failure(error)
        }

        let matchedCalendars: [EKCalendar]?
        switch calendars(matching: query.calendarNames) {
        case .success(let matched):
            matchedCalendars = matched
        case .failure(let error):
            return .failure(error)
        }

        let predicate = store.predicateForEvents(
            withStart: query.start,
            end: query.end,
            calendars: matchedCalendars
        )
        let events = store.events(matching: predicate)
            .filter { eventMatchesText($0, query: query) }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(query.maxResults)
            .map { Self.calendarEvent(from: $0, includeNotes: query.includeNotes) }
        return .success(Array(events))
    }

    private func ensureFullAccess() async -> Result<Void, CalendarLookupError> {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .success(())
        case .notDetermined:
            return await requestFullAccess()
        case .denied, .writeOnly:
            return .failure(.permissionDenied)
        case .restricted:
            return .failure(.restricted)
        case .authorized:
            return .success(())
        @unknown default:
            return .failure(.unavailable("calendar access is unavailable on this device."))
        }
    }

    private func requestFullAccess() async -> Result<Void, CalendarLookupError> {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if granted {
                    continuation.resume(returning: .success(()))
                } else if let error {
                    continuation.resume(returning: .failure(.unavailable(
                        "couldn't request Calendar access: \(error.localizedDescription)"
                    )))
                } else {
                    continuation.resume(returning: .failure(.permissionDenied))
                }
            }
        }
    }

    private func calendars(matching names: [String]) -> Result<[EKCalendar]?, CalendarLookupError> {
        guard !names.isEmpty else { return .success(nil) }
        let all = store.calendars(for: .event)
        let matched = all.filter { calendar in
            names.contains { requested in
                calendar.title.localizedCaseInsensitiveContains(requested)
                    || requested.localizedCaseInsensitiveContains(calendar.title)
            }
        }
        guard !matched.isEmpty else {
            let requested = names.joined(separator: ", ")
            let available = all.map(\.title).sorted().joined(separator: ", ")
            return .failure(.unavailable(
                "no calendars matched \(requested). Available calendars: \(available)"
            ))
        }
        return .success(matched)
    }

    private func eventMatchesText(_ event: EKEvent, query: CalendarEventQuery) -> Bool {
        guard let needle = query.matching?.trimmingCharacters(in: .whitespacesAndNewlines),
              !needle.isEmpty else { return true }
        let haystack = [
            event.title,
            event.location,
            event.notes,
            event.calendar.title,
        ]
        return haystack.contains {
            ($0 ?? "").localizedCaseInsensitiveContains(needle)
        }
    }

    private static func calendarEvent(
        from event: EKEvent, includeNotes: Bool
    ) -> CalendarEvent {
        CalendarEvent(
            title: trimmed(event.title) ?? "(untitled)",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar.title,
            location: trimmed(event.location),
            notes: includeNotes ? truncated(trimmed(event.notes), maxLength: 500) : nil
        )
    }

    private static func truncated(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
