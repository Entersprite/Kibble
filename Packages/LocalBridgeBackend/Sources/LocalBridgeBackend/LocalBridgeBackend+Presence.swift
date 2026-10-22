import ChatKit
import Foundation
import GChatBridgeCore

/// Presence for every person this session has put a face to, polled.
///
/// **Polled, because nothing pushes it.** purple asks `get_user_presence`
/// every 120 seconds, and its handler for the channel's
/// `USER_STATUS_UPDATED_EVENT` notes that event carries do not disturb but not
/// active/inactive ("fetch presence separately from status",
/// `googlechat_events.c`). This follows the reference; whether this account's
/// channel carries anything presence-shaped is `[Verify]`.
///
/// **Who: every person `get_members` has named this session.** That is DM and
/// group-chat members from the world load, plus every sender and typer looked
/// up on demand (`resolveUnknownMembers`) - everyone whose face the app can
/// show, in the sidebar or beside a message. Apps are left out: they have no
/// presence. It is also exactly the set with member rows, which `.setPresence`
/// needs (an UPDATE; see `startPresencePoll`). The set only grows within a
/// session, and one request carries all of it; how many ids one request can
/// hold is `[Verify]` (`findings.md` §45.3).
extension LocalBridgeBackend {
    /// What the poll holds between runs. One stored property on the actor,
    /// because `LocalBridgeBackend.swift` sits at `file_length`.
    struct PresencePoll {
        /// The running poll, if any. Replaced by every world load, cancelled
        /// by `disconnect()` and a terminal channel stop.
        var task: Task<Void, Never>?
        /// Who is asked about. Grown by `addPresenceTargets`, cleared with
        /// the session.
        var people: Set<ChatKit.Member.ID> = []
        var clientPeople: Set<ChatKit.Member.ID> = []
        var allPeople: Set<ChatKit.Member.ID> {
            people.union(clientPeople)
        }

        /// The last value emitted per person, so a poll that learns nothing
        /// new emits nothing. Cleared by `disconnect()`.
        var emitted: [ChatKit.Member.ID: EmittedPresence] = [:]
        /// The last status emitted per person, the same way. Only people who
        /// have had one are here: a status that is cleared is removed.
        var statuses: [ChatKit.Member.ID: MemberStatus] = [:]
        /// Whether the current run of failures has been reported, so a poll
        /// failing every two minutes raises one error rather than one per
        /// attempt. Reset by the next success.
        var failureReported = false
        /// The client's last `reportActivity`. **Kept by `stopPresencePoll`**,
        /// so the next connect resumes reporting without being told again.
        var deviceInUse = false
        /// The activity loop (`+Activity.swift`), stopped with the poll.
        var activityTask: Task<Void, Never>?
        /// How many rounds the activity loop has finished since the poll was
        /// reset, suppressed ones included. Nothing in the app reads it: a
        /// round under Away or Do not disturb sends nothing, so tests wait on
        /// this to know one ran, never on a clock (`CLAUDE.md`, Testing).
        var activityRounds = 0
        /// The availability this backend last reported, which decides whether
        /// activity is reported at all; learned again at connect.
        var ownAvailability: Availability?
        /// Whether this connect's self-identification has finished, so
        /// `ownAvailability` is known if it can be. Reporting waits for it, or
        /// Away would lose to the app's report racing `get_self_user_status`
        /// (review finding 1). Reset with the poll.
        var selfResolved = false
    }

    /// purple's interval (`googlechat_auth.c`, `poll_buddy_status_timeout`).
    static let defaultPresencePollInterval: Duration = .seconds(120)
    /// The first retry after a failed poll, doubling while it keeps failing,
    /// up to the interval.
    static let defaultPresenceRetryDelay: Duration = .seconds(10)

    /// What a person who was answered for before, and is missing from a
    /// successful answer now, becomes: something that draws nothing. Leaving
    /// the old value would keep a dot green for as long as the process runs.
    static let absentPresence = ChatKit.Presence.unknown("absent")

    /// One person's last emitted presence and Do not disturb end.
    struct EmittedPresence: Equatable {
        var presence: ChatKit.Presence
        var doNotDisturbUntil: Date?

        /// An end read from a remaining duration moves with each answer's
        /// own clock, so ends this close together are the same end, or every
        /// poll would emit again for someone whose Do not disturb has not
        /// changed.
        static let endTolerance: TimeInterval = 5

        func says(_ other: Self?) -> Bool {
            guard let other, presence == other.presence else { return false }
            switch (doNotDisturbUntil, other.doNotDisturbUntil) {
            case (nil, nil): return true
            case let (mine?, theirs?): return abs(mine.timeIntervalSince(theirs)) <= Self.endTolerance
            default: return false
            }
        }
    }

    /// The people among `members`: presence is asked about humans only. The
    /// local user is included when named, which costs one id and draws
    /// nothing.
    static func presenceTargets(from members: [ChatKit.Member]) -> [ChatKit.Member.ID] {
        Set(members.filter { $0.kind == .human }.map(\.id)).sorted { $0.rawValue < $1.rawValue }
    }

    /// Adds the people among `members` to the poll, once their names - and
    /// so their member rows - have been emitted.
    ///
    /// With `immediately`, anyone new is asked about at once rather than at
    /// the next interval, so opening a space shows its senders' dots within a
    /// moment instead of up to two minutes later. Only while a poll is
    /// running: before the first world load, the loop's first run picks them
    /// up.
    func addPresenceTargets(
        _ members: [ChatKit.Member],
        immediately: Bool,
        using apiClient: ProtoAPIClient,
        generation: Int
    ) {
        addPresenceTargets(
            ids: Self.presenceTargets(from: members), immediately: immediately, using: apiClient,
            generation: generation
        )
    }

    /// `ChatCommand.watchPresence`: people a client has on screen, asked
    /// about at once, whether or not the poll already asks about them. A
    /// client names them when a conversation opens, and what it shows there,
    /// such as the other person's Do not disturb in a DM, should be news
    /// from now rather than up to an interval old.
    ///
    /// The client names people this backend may never have fetched a page
    /// for this session - a transcript shows every stored message, from every
    /// earlier launch - and whose names are already known, so no lookup here
    /// will ever add them. The client sends only people with a member row, so
    /// `.setPresence` cannot drop the answer, and only people, so no kind
    /// check is needed here.
    ///
    /// **Ignored unless connected** - `apiClient` exists exactly then;
    /// `disconnect()` and a channel stop clear it with `isConnected`. A hint
    /// that outlived its session - a selection racing a sign-out - must not
    /// seed the next session's poll with another account's contacts. The
    /// client re-sends when the connection comes back.
    func watchPresence(_ ids: [ChatKit.Member.ID]) {
        guard let apiClient else { return }
        let people = Set(ids.filter { !$0.rawValue.isEmpty }).sorted { $0.rawValue < $1.rawValue }
        presencePoll.people.formUnion(people)
        guard !people.isEmpty, presencePoll.task != nil else { return }
        let generation = directoryGeneration
        Task { [weak self] in
            await self?.pollPresence(people, using: apiClient, generation: generation)
        }
    }

    private func addPresenceTargets(
        ids: [ChatKit.Member.ID],
        immediately: Bool,
        using apiClient: ProtoAPIClient,
        generation: Int
    ) {
        let new = ids.filter { !presencePoll.people.contains($0) }
        guard !new.isEmpty else { return }
        presencePoll.people.formUnion(new)
        guard immediately, presencePoll.task != nil else { return }
        Task { [weak self] in
            await self?.pollPresence(new, using: apiClient, generation: generation)
        }
    }

    /// Starts the account poll once; directory reads only add targets.
    ///
    /// **The first run waits for `names`, the world load's `get_members`.**
    /// `.setPresence` is an UPDATE and drops presence for anyone the store has
    /// no member row for, and member rows come only from that lookup. An
    /// answer that landed first would be dropped, and because `emitted`
    /// already recorded it, never sent again: on a fresh store, every dot
    /// would stay missing until that person's state changed. Awaiting a task
    /// is not cancelling it, so this cannot finish the lookup early.
    ///
    /// **A failed run asks again soon**, after `presenceRetryDelay`, doubling
    /// while it keeps failing, up to the interval. The failure has just
    /// withdrawn every dot it asked about, and the likeliest failure is the
    /// first run after the Mac wakes, whose two minutes ran out during sleep
    /// and which goes out before the network is back: waiting a whole
    /// interval left the sidebar without a single dot for two minutes after
    /// every wake (owner's report, session320).
    func startPresencePoll(using apiClient: ProtoAPIClient, after names: Task<Void, Never>?) {
        guard presencePoll.task == nil else { return }
        let interval = presencePollInterval
        let firstRetry = presenceRetryDelay
        let generation = directoryGeneration
        presencePoll.task = Task { [weak self] in
            await names?.value
            var retry = firstRetry
            while !Task.isCancelled {
                // `nil` once the backend has gone, which ends the loop rather
                // than sleeping forever on behalf of nobody. Read fresh each
                // run, because the set grows between runs.
                guard let people = await self?.presencePoll.allPeople else { return }
                var answered = true
                if !people.isEmpty {
                    let ids = people.sorted { $0.rawValue < $1.rawValue }
                    answered = await self?.pollPresence(ids, using: apiClient, generation: generation) ?? true
                }
                let wait = answered ? interval : min(retry, interval)
                retry = answered ? firstRetry : min(retry * 2, interval)
                do {
                    try await Task.sleep(for: wait)
                } catch {
                    return
                }
            }
        }
    }

    /// Asks about everyone now, and then on the usual schedule: the loop
    /// starts over, keeping who it asks about and what it last said. For a
    /// channel that came back after an outage, whose dots are as old as the
    /// outage. Nothing while no poll runs: the next world load starts one.
    func pollPresenceNow() {
        guard let apiClient, presencePoll.task != nil else { return }
        presencePoll.task?.cancel()
        presencePoll.task = nil
        PresenceLog.restarted()
        startPresencePoll(using: apiClient, after: nil)
    }

    func stopPresencePoll() {
        presencePoll.task?.cancel()
        presencePoll.activityTask?.cancel()
        presencePoll = PresencePoll(deviceInUse: presencePoll.deviceInUse)
    }

    /// One `get_user_presence` call, and a `.presenceChanged` for each person
    /// whose answer differs from the last one emitted.
    ///
    /// **Never throws**, `resolveAndEmitMembers`' posture: a failed poll is a
    /// stale dot, not a broken session.
    ///
    /// Two stale checks after the await, because there are two kinds of
    /// caller. The loop is cancelled when replaced or stopped. A one-off from
    /// `addPresenceTargets` is never cancelled, so it carries the directory
    /// generation, which every end of a session bumps (`forgetDirectory`).
    ///
    /// Returns whether Google answered, so the loop can ask again soon after
    /// a failure; a stale call counts as answered, since nobody waits on it.
    @discardableResult
    func pollPresence(
        _ ids: [ChatKit.Member.ID], using apiClient: ProtoAPIClient, generation: Int
    ) async -> Bool {
        let response: GetUserPresenceResponse
        do {
            response = try await apiClient.call(.getUserPresence, Self.getUserPresenceRequest(ids))
        } catch {
            // A poll from a session that has gone, or one replaced while the
            // call was out: its failure is not news.
            guard !Task.isCancelled, generation == directoryGeneration else { return true }
            PresenceLog.failed(asked: ids.count, error: error)
            // Withdraw first, then report: every withdrawal event passes
            // through `SyncReducer.supersedingStaleError`, which clears the
            // last error, so an error emitted first was erased at once -
            // and, reported once per run, never shown. `channelStopped`
            // orders its own the same way.
            withdrawPresence(ids)
            if !presencePoll.failureReported {
                presencePoll.failureReported = true
                reportResourceFailure(
                    .presence,
                    error: Self.chatError(fromAPI: error, call: "the /api/ get_user_presence call")
                )
            }
            return false
        }
        // The same checks: a stale session's presence must not land in the
        // next one.
        guard !Task.isCancelled, generation == directoryGeneration else { return true }
        presencePoll.failureReported = false
        resourceRecovered(.presence)
        let answered = PresenceMapping.map(response)
        PresenceLog.answered(asked: ids.count, answered: answered.count)
        let ends = PresenceMapping.doNotDisturbEnds(response, now: Date())
        for id in ids {
            let previous = presencePoll.emitted[id]
            let presence = answered[id] ?? previous.map { _ in Self.absentPresence }
            guard let presence else { continue }
            let next = EmittedPresence(
                presence: presence,
                doNotDisturbUntil: answered[id] == nil ? nil : ends[id]
            )
            guard !next.says(previous) else { continue }
            presencePoll.emitted[id] = next
            guard await emitCommitted(.presenceChanged(
                member: id, presence: next.presence, doNotDisturbUntil: next.doNotDisturbUntil
            )) else { return true }
        }
        await emitStatusChanges(for: ids, in: response)
        return true
    }

    /// A `.statusChanged` for each person whose status differs from the last
    /// one emitted. Someone answered without a `user_status` says nothing and
    /// keeps theirs; someone missing from the answer altogether loses theirs,
    /// as their dot does; someone who never had one emits nothing for none.
    private func emitStatusChanges(for ids: [ChatKit.Member.ID], in response: GetUserPresenceResponse) async {
        let answered = Set(response.userPresences.map { ChatKit.Member.ID($0.userID.id) })
        let statuses = PresenceMapping.statuses(response, now: Date())
        for id in ids {
            let next: MemberStatus?
            if let reported = statuses[id] {
                next = reported
            } else if answered.contains(id) {
                continue
            } else {
                next = nil
            }
            guard next != presencePoll.statuses[id] else { continue }
            presencePoll.statuses[id] = next
            guard await emitCommitted(.statusChanged(member: id, status: next)) else { return }
        }
    }

    /// Every dot the poll has shown for `ids` becomes `absentPresence`, every
    /// status is cleared, and both are forgotten so the next success shows
    /// them again.
    ///
    /// A failed poll cannot confirm anything, and a dot is a claim about now.
    /// Without this, one success followed by any run of failures (an expired
    /// token, a server change) would leave every dot on that answer for the
    /// life of the process - with a setter and no clearer (`CLAUDE.md`, a
    /// field written by a snapshot is stale in both directions). The cost is a
    /// dot that vanishes for one interval after a transient failure.
    ///
    /// Only for `ids`, the people the failed call asked about: a one-off for
    /// one sender that fails says nothing about everyone the loop answered
    /// for, whose dots would otherwise vanish for up to an interval.
    private func withdrawPresence(_ ids: [ChatKit.Member.ID]) {
        for id in ids {
            if let emitted = presencePoll.emitted.removeValue(forKey: id),
               emitted.presence != Self.absentPresence {
                emit(.presenceChanged(member: id, presence: Self.absentPresence))
            }
            if presencePoll.statuses.removeValue(forKey: id) != nil {
                emit(.statusChanged(member: id, status: nil))
            }
        }
    }

    /// The reference's request shape: `purple`'s `googlechat_get_users_presence`
    /// sets both `include_user_status` (which is where DND can be carried) and
    /// `include_active_until`.
    static func getUserPresenceRequest(_ ids: [ChatKit.Member.ID]) -> GetUserPresenceRequest {
        var request = GetUserPresenceRequest()
        request.requestHeader = APIRequestHeader.make()
        request.userIds = ids.map { id in
            var userID = UserId()
            userID.id = id.rawValue
            return userID
        }
        request.includeUserStatus = true
        request.includeActiveUntil = true
        return request
    }
}
