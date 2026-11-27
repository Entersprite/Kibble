import Foundation
import GChatBridgeCore

/// Calendar's own range read supplements the existing availability poll with
/// titles for conference links. It uses the same verified local identity.
extension LocalBridgeBackend {
    func calendarMeetingTitle(_ link: MeetJoinLink, at reference: Date?) async throws -> String? {
        let date = reference ?? Date()
        guard let events = try await calendarMeetingOccurrences(at: date) else { return nil }
        let title = CalendarMeetingTitles.title(in: events, for: link, at: date)
        diagnostics.record(.calendarWebRead(stage: "title-match", value: title == nil ? 0 : 1))
        return title
    }

    /// Checks the same read used by Meet links, even on a calendar with no events.
    public func checkCalendarMeetingTitleAccess() async -> Bool {
        await (try? calendarMeetingOccurrences(at: Date(), refresh: true)) != nil
    }

    private func calendarMeetingOccurrences(at date: Date, refresh: Bool = false) async throws
        -> [CalendarWebOccurrence]? {
        let generation = directoryGeneration
        guard let email = try await calendarTitleOwner(generation: generation) else { return nil }
        let seconds = date.timeIntervalSince1970
        guard (0 ... 253_394_524_799).contains(seconds) else { return nil }
        let day = Date(timeIntervalSince1970: floor(seconds / 86400) * 86400)
        let key = CalendarMeetingTitles.Key(day: day, email: email)
        if !refresh, let cached = calendarPoll.meetingTitles.cached(for: key) {
            return try cached.get()
        }
        let client = CalendarWebEventClient(
            transport: transport,
            credentials: calendarPoll.titleCredentials ?? credentials,
            endpoints: endpoints
        )
        let pending = calendarPoll.meetingTitles.read(key, via: client, diagnostics: diagnostics)
        guard let pending else { return nil }
        let result = await pending.task.result
        guard !pending.task.isCancelled, isConnected, directoryGeneration == generation,
              calendarPoll.me.flatMap({ memberEmails[$0] }) == email else { throw CancellationError() }
        calendarPoll.meetingTitles.complete(result, for: key, id: pending.id)
        try Task.checkCancellation()
        return try result.get()
    }

    func calendarTitleOwner(generation: Int) async throws -> String? {
        guard isConnected else { return nil }
        if calendarPoll.me.flatMap({ memberEmails[$0] }) == nil {
            await selfIdentification?.value
        }
        try Task.checkCancellation()
        guard isConnected, directoryGeneration == generation else { return nil }
        return calendarPoll.me.flatMap { memberEmails[$0] }
    }
}

struct CalendarMeetingTitles {
    struct Key: Hashable {
        let day: Date
        let email: String
    }

    struct Read {
        let id: UUID
        let task: Task<[CalendarWebOccurrence], any Error>
    }

    struct Window {
        let result: Result<[CalendarWebOccurrence], any Error>
        let expires: Date
    }

    private var windows: [Key: Window] = [:]
    private var pending: [Key: Read] = [:]

    mutating func cached(for key: Key) -> Result<[CalendarWebOccurrence], any Error>? {
        let now = Date()
        windows = windows.filter { $0.value.expires > now }
        return windows[key]?.result
    }

    mutating func read(
        _ key: Key,
        via client: CalendarWebEventClient,
        diagnostics: ProviderDiagnostics
    ) -> Read? {
        if let read = pending[key] {
            return read
        }
        guard pending.count < 4 else { return nil }
        let read = Read(id: UUID(), task: Task {
            try await client.occurrences(around: key.day, email: key.email) { stage, value in
                diagnostics.record(.calendarWebRead(stage: stage, value: value))
            }
        })
        pending[key] = read
        return read
    }

    mutating func complete(_ result: Result<[CalendarWebOccurrence], any Error>, for key: Key, id: UUID) {
        guard pending[key]?.id == id else { return }
        pending[key] = nil
        let events = try? result.get()
        if windows.count >= 4, let oldest = windows.min(by: { $0.value.expires < $1.value.expires })?.key {
            windows[oldest] = nil
        }
        windows[key] = Window(
            result: result,
            expires: Date().addingTimeInterval(events == nil ? 15 : 60)
        )
    }

    func cancel() {
        for read in pending.values {
            read.task.cancel()
        }
    }

    static func title(in events: [CalendarWebOccurrence], for link: MeetJoinLink, at date: Date) -> String? {
        let matches = events.filter { $0.meetCode == link.code }
        let unique = Dictionary(grouping: matches, by: \.identity).values.flatMap { copies in
            let primary = copies.filter(\.isOnPrimaryCalendar)
            return primary.isEmpty ? copies : primary
        }
        let active = unique.filter { $0.start <= date && date < $0.end }
        if !active.isEmpty {
            return commonTitle(active)
        }
        let upcoming = unique.filter { $0.start > date }
        if let first = upcoming.map(\.start).min() {
            return commonTitle(upcoming.filter { $0.start == first })
        }
        guard let last = unique.map(\.start).max() else { return nil }
        return commonTitle(unique.filter { $0.start == last })
    }

    private static func commonTitle(_ occurrences: [CalendarWebOccurrence]) -> String? {
        let titles = Set(occurrences.map(\.title))
        return titles.count == 1 ? titles.first : nil
    }
}
