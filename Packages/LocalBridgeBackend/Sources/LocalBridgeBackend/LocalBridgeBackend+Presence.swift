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
        /// The last value emitted per person, so a poll that learns nothing
        /// new emits nothing. Cleared by `disconnect()`.
        var emitted: [ChatKit.Member.ID: ChatKit.Presence] = [:]
        /// The last status emitted per person, the same way. Only people who
        /// have had one are here: a status that is cleared is removed.
        var statuses: [ChatKit.Member.ID: MemberStatus] = [:]
        /// Whether the current run of failures has been reported, so a poll
        /// failing every two minutes raises one error rather than one per
        /// attempt. Reset by the next success.
        var failureReported = false
    }

    /// purple's interval (`googlechat_auth.c`, `poll_buddy_status_timeout`).
    static let defaultPresencePollInterval: Duration = .seconds(120)

    /// What a person who was answered for before, and is missing from a
    /// successful answer now, becomes: something that draws nothing. Leaving
    /// the old value would keep a dot green for as long as the process runs.
    static let absentPresence = ChatKit.Presence.unknown("absent")

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
    /// about at once.
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
        addPresenceTargets(ids: people, immediately: true, using: apiClient, generation: directoryGeneration)
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

    /// Starts the poll, replacing any already running - a world reload
    /// restarts it with an immediate run.
    ///
    /// **The first run waits for `names`, the world load's `get_members`.**
    /// `.setPresence` is an UPDATE and drops presence for anyone the store has
    /// no member row for, and member rows come only from that lookup. An
    /// answer that landed first would be dropped, and because `emitted`
    /// already recorded it, never sent again: on a fresh store, every dot
    /// would stay missing until that person's state changed. Awaiting a task
    /// is not cancelling it, so this cannot finish the lookup early.
    func startPresencePoll(using apiClient: ProtoAPIClient, after names: Task<Void, Never>?) {
        presencePoll.task?.cancel()
        let interval = presencePollInterval
        let generation = directoryGeneration
        presencePoll.task = Task { [weak self] in
            await names?.value
            while !Task.isCancelled {
                // `nil` once the backend has gone, which ends the loop rather
                // than sleeping forever on behalf of nobody. Read fresh each
                // run, because the set grows between runs.
                guard let people = await self?.presencePoll.people else { return }
                if !people.isEmpty {
                    let ids = people.sorted { $0.rawValue < $1.rawValue }
                    await self?.pollPresence(ids, using: apiClient, generation: generation)
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    func stopPresencePoll() {
        presencePoll.task?.cancel()
        presencePoll = PresencePoll()
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
    func pollPresence(_ ids: [ChatKit.Member.ID], using apiClient: ProtoAPIClient, generation: Int) async {
        let response: GetUserPresenceResponse
        do {
            response = try await apiClient.call(.getUserPresence, Self.getUserPresenceRequest(ids))
        } catch {
            // A poll from a session that has gone, or one replaced while the
            // call was out: its failure is not news.
            guard !Task.isCancelled, generation == directoryGeneration else { return }
            // Withdraw first, then report: every withdrawal event passes
            // through `SyncReducer.supersedingStaleError`, which clears the
            // last error, so an error emitted first was erased at once -
            // and, reported once per run, never shown. `channelStopped`
            // orders its own the same way.
            withdrawPresence(ids)
            if !presencePoll.failureReported {
                presencePoll.failureReported = true
                emit(.backendError(Self.chatError(fromAPI: error, call: "the /api/ get_user_presence call")))
            }
            return
        }
        // The same checks: a stale session's presence must not land in the
        // next one.
        guard !Task.isCancelled, generation == directoryGeneration else { return }
        presencePoll.failureReported = false
        let answered = PresenceMapping.map(response)
        for id in ids {
            let previous = presencePoll.emitted[id]
            guard let next = answered[id] ?? previous.map({ _ in Self.absentPresence }),
                  next != previous
            else { continue }
            presencePoll.emitted[id] = next
            emit(.presenceChanged(member: id, presence: next))
        }
        emitStatusChanges(for: ids, in: response)
    }

    /// A `.statusChanged` for each person whose status differs from the last
    /// one emitted. Someone answered without a `user_status` says nothing and
    /// keeps theirs; someone missing from the answer altogether loses theirs,
    /// as their dot does; someone who never had one emits nothing for none.
    private func emitStatusChanges(for ids: [ChatKit.Member.ID], in response: GetUserPresenceResponse) {
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
            emit(.statusChanged(member: id, status: next))
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
            if let presence = presencePoll.emitted.removeValue(forKey: id), presence != Self.absentPresence {
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
