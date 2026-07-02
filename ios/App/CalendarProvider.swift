import EventKit
import Foundation
import PhantasmKit

/// EventKit-backed `CalendarProviding` for the app-hosted Calendar tools. Lives
/// in the app target (EventKit is kept out of `PhantasmKit` so the package stays
/// host-testable); the pure tool types hold this behind the protocol.
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
        // events(matching:) is a synchronous fetch Apple documents as
        // background-thread work, and the range is model-controlled — a large
        // calendar window must not stall the main actor mid-turn. EKEventStore
        // is thread-safe; only value types cross back.
        let store = self.store
        let events = await Task.detached(priority: .userInitiated) {
            Array(
                store.events(matching: predicate)
                    .filter { Self.eventMatchesText($0, query: query) }
                    .sorted {
                        if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                    .prefix(query.maxResults)
                    .map { Self.calendarEvent(from: $0, includeNotes: query.includeNotes) }
            )
        }.value
        return .success(events)
    }

    func createEvent(_ draft: CalendarEventDraft) async -> Result<CalendarEvent, CalendarLookupError> {
        switch await ensureWriteAccess() {
        case .success:
            break
        case .failure(let error):
            return .failure(error)
        }

        let calendar: EKCalendar
        switch calendarForNewEvent(named: draft.calendarTitle) {
        case .success(let selected):
            calendar = selected
        case .failure(let error):
            return .failure(error)
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return .success(Self.calendarEvent(from: event, includeNotes: true))
        } catch {
            return .failure(.unavailable(
                "couldn't create the Calendar event: \(error.localizedDescription)"
            ))
        }
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

    private func ensureWriteAccess() async -> Result<Void, CalendarLookupError> {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            return .success(())
        case .notDetermined:
            return await requestFullAccess()
        case .denied:
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

    private func calendarForNewEvent(named name: String?) -> Result<EKCalendar, CalendarLookupError> {
        let writable = store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        if let name = Self.trimmed(name) {
            if let matched = writable.first(where: { calendar in
                calendar.title.localizedCaseInsensitiveContains(name)
                    || name.localizedCaseInsensitiveContains(calendar.title)
            }) {
                return .success(matched)
            }
            let available = writable.map(\.title).joined(separator: ", ")
            return .failure(.unavailable(
                "no writable calendars matched \(name). Writable calendars: \(available)"
            ))
        }

        if let defaultCalendar = store.defaultCalendarForNewEvents,
           defaultCalendar.allowsContentModifications {
            return .success(defaultCalendar)
        }
        if let firstWritable = writable.first {
            return .success(firstWritable)
        }
        return .failure(.unavailable("no writable Calendar is available on this device."))
    }

    nonisolated private static func eventMatchesText(_ event: EKEvent, query: CalendarEventQuery) -> Bool {
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

    nonisolated private static func calendarEvent(
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

    nonisolated private static func truncated(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    nonisolated private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
