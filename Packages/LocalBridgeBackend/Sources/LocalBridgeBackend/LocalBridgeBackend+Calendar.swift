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
        for id in people {
            let next = answered[id]
            guard next != calendarPoll.emitted[id] else { continue }
            calendarPoll.emitted[id] = next
            emit(.calendarChanged(member: id, schedule: next))
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
