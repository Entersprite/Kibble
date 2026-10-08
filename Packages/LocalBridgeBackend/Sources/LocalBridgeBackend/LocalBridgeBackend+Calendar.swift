import ChatKit
import Foundation
import GChatBridgeCore

/// Calendar status for the local user and every DM member, polled from
/// PeopleStack `GetAssistiveFeatures` (meeting indicator spec §3.1,
/// `findings.md` §62).
///
/// **Polled, as Chat on the web does** (every 30 minutes there). Each answer
/// covers about twelve hours and the client redraws at boundaries itself, so
/// a poll only catches meetings added or cancelled.
///
/// **Who:** every member of a one-to-one DM in the last world load, which
/// includes the local user, plus the local user from `get_self_user_status`
/// for an account with no DM. Asked by person id, signed with the people
/// search's key and `SAPISIDHASH` alone (§62.10).
extension LocalBridgeBackend {
    /// What the poll holds between runs: one stored property on the actor,
    /// because `LocalBridgeBackend.swift` sits at `file_length`.
    struct CalendarPoll {
        var task: Task<Void, Never>?
        /// DM members from the last world load.
        var people: Set<ChatKit.Member.ID> = []
        /// The local user, once `get_self_user_status` has answered.
        var me: ChatKit.Member.ID?
        /// The last schedule emitted per person; someone cleared is removed.
        var emitted: [ChatKit.Member.ID: CalendarSchedule] = [:]
        /// Whether the current run of failures has been reported.
        var failureReported = false
        var interval: Duration = LocalBridgeBackend.defaultCalendarPollInterval
    }

    /// Short-notice meetings show within this; transitions need no poll.
    static let defaultCalendarPollInterval: Duration = .seconds(600)

    /// People per request: 10 were measured in one (§62.10); the limit is
    /// `[Verify]`.
    static let calendarBatchSize = 25

    /// A stored schedule is sent again this long before its `validUntil`, so
    /// a day that has not changed is not cut off when the window runs out.
    static let calendarRefreshMargin: TimeInterval = 2 * 3600

    /// Tests only.
    func setCalendarPollInterval(_ interval: Duration) {
        calendarPoll.interval = interval
    }

    /// Every member of a one-to-one DM: the partners, and the local user.
    static func calendarTargets(from conversations: [Conversation]) -> Set<ChatKit.Member.ID> {
        Set(conversations.filter { $0.kind == .directMessage }.flatMap(\.members))
    }

    /// Starts the poll, replacing any already running. The first run waits
    /// for `lookups`, the name lookups that create the member rows its UPDATE
    /// writes to (`startPresencePoll` explains the race).
    func startCalendarPoll(for conversations: [Conversation], after lookups: [Task<Void, Never>?]) {
        calendarPoll.task?.cancel()
        calendarPoll.people = Self.calendarTargets(from: conversations)
        // Everyone is sent once more: a write dropped because the person had
        // no row yet (a failed lookup) is healed by the next world load.
        calendarPoll.emitted = [:]
        let generation = directoryGeneration
        calendarPoll.task = Task { [weak self] in
            for lookup in lookups {
                await lookup?.value
            }
            while !Task.isCancelled {
                guard let interval = await self?.calendarPoll.interval else { return }
                await self?.pollCalendars(generation: generation)
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Both polls, stopped together by `disconnect()` and a stopped channel.
    func stopPolls() {
        stopPresencePoll()
        calendarPoll.task?.cancel()
        calendarPoll = CalendarPoll(interval: calendarPoll.interval)
    }

    /// One run: every person, in batches, then a `.calendarChanged` for each
    /// whose schedule differs from the last one emitted. **Never throws.**
    func pollCalendars(generation: Int) async {
        var ids = calendarPoll.people
        if let me = calendarPoll.me {
            ids.insert(me)
        }
        let people = ids.filter { !$0.rawValue.isEmpty }.sorted { $0.rawValue < $1.rawValue }
        guard isConnected, !people.isEmpty else { return }
        // A missing key is reported once per session by the lookup itself.
        guard let key = try? await peopleSearchKey(), isCurrent(generation) else { return }
        var answered: [ChatKit.Member.ID: CalendarSchedule] = [:]
        for start in stride(from: 0, to: people.count, by: Self.calendarBatchSize) {
            let batch = Array(people[start ..< min(start + Self.calendarBatchSize, people.count)])
            let schedules = await fetchCalendars(batch, key: key)
            guard isCurrent(generation) else { return }
            guard let schedules else {
                reportCalendarFailure()
                return
            }
            answered.merge(schedules) { _, new in new }
        }
        calendarPoll.failureReported = false
        let now = Date()
        for id in people {
            let next = answered[id]
            guard !Self.drawsTheSame(calendarPoll.emitted[id], next, now: now) else { continue }
            calendarPoll.emitted[id] = next
            emit(.calendarChanged(member: id, schedule: next))
        }
    }

    /// Whether `next` draws the same as `emitted` from `now` on.
    ///
    /// Every answer moves its first start and its `validUntil` with the
    /// server's clock (§62.10), so comparing values emitted for everyone on
    /// every poll (whole-branch review, finding 1). What draws is each entry's
    /// kind, end and "until", and a start still ahead, up to the horizon both
    /// answers cover. A stored schedule near its own `validUntil` never draws
    /// the same, so it is renewed before it runs out.
    static func drawsTheSame(_ emitted: CalendarSchedule?, _ next: CalendarSchedule?, now: Date) -> Bool {
        guard let emitted, let next else { return emitted == nil && next == nil }
        if let end = emitted.validUntil, end.timeIntervalSince(now) < calendarRefreshMargin {
            return false
        }
        let horizon = min(emitted.validUntil ?? .distantFuture, next.validUntil ?? .distantFuture)
        return drawn(emitted, now: now, horizon: horizon) == drawn(next, now: now, horizon: horizon)
    }

    /// The entries that can still draw, cut to `[now, horizon)`.
    private static func drawn(
        _ schedule: CalendarSchedule,
        now: Date,
        horizon: Date
    ) -> [CalendarSchedule.Entry] {
        schedule.entries.filter { $0.end > now && $0.start < horizon }.map { entry in
            var entry = entry
            entry.start = max(entry.start, now)
            entry.end = min(entry.end, horizon)
            entry.until = entry.until.map { min($0, horizon) }
            return entry
        }
    }

    /// Not cancelled, and the session that started the run is still this one.
    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == directoryGeneration
    }

    /// One request for `batch`: the schedules it answered (someone "not
    /// found" or missing is absent), or `nil` for a failure.
    private func fetchCalendars(
        _ batch: [ChatKit.Member.ID],
        key: String
    ) async -> [ChatKit.Member.ID: CalendarSchedule]? {
        let jar = await credentials.snapshot?.cookies ?? []
        let input = SAPISIDHash.Input(
            cookies: jar,
            url: PeopleStackRequests.getAssistiveFeaturesURL,
            origin: PeopleRequests.origin(of: endpoints),
            timestamp: Int(Date().timeIntervalSince1970)
        )
        let request = PeopleStackRequests.getAssistiveFeatures(
            [.init(keys: batch.map { .personID($0.rawValue) }, features: [.calendarStatus])],
            client: 1,
            key: key,
            authorization: SAPISIDHash.authorization(.sapisidOnly, for: input, sha1: SHA1.hex),
            endpoints: endpoints
        )
        let client = PunctualClient(transport: transport, credentials: credentials)
        guard let response = try? await client.send(request), response.status == 200,
              let answer = PeopleStackAnswer(response.body)
        else { return nil }
        let arrivedAt = Date()
        var schedules: [ChatKit.Member.ID: CalendarSchedule] = [:]
        for entry in answer.calendar where entry.key.type == 2 {
            schedules[ChatKit.Member.ID(entry.key.value)] = CalendarMapping.schedule(
                entry.payload, entryStatus: entry.status, arrivedAt: arrivedAt
            )
        }
        return schedules
    }

    /// Once per run of failures. Schedules are kept, not withdrawn: a
    /// schedule stays true while a fetch fails, and the client cuts it at
    /// `validUntil` anyway.
    private func reportCalendarFailure() {
        guard !calendarPoll.failureReported else { return }
        calendarPoll.failureReported = true
        emit(.backendError(.unknown("the calendar status call failed")))
    }
}
