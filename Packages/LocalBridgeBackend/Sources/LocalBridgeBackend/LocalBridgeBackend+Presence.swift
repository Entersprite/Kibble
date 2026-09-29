import ChatKit
import Foundation
import GChatBridgeCore

/// Presence for the people you DM, polled.
///
/// **Polled, because nothing pushes it.** purple asks `get_user_presence`
/// every 120 seconds, and its handler for the channel's
/// `USER_STATUS_UPDATED_EVENT` notes that event carries do not disturb but not
/// active/inactive ("fetch presence separately from status",
/// `googlechat_events.c`). This follows the reference; whether this account's
/// channel carries anything presence-shaped is `[Verify]`.
///
/// **Only DM partners.** They are the only people whose presence is drawn
/// (the sidebar's DM rows and the open DM's header), so polling anyone else
/// would be requests nobody reads. A space's members are never listed by the
/// world anyway (`findings.md` §37.5).
extension LocalBridgeBackend {
    /// What the poll holds between runs. One stored property on the actor,
    /// because `LocalBridgeBackend.swift` sits at `file_length`.
    struct PresencePoll {
        /// The running poll, if any. Replaced by every world load, cancelled
        /// by `disconnect()`.
        var task: Task<Void, Never>?
        /// The last value emitted per person, so a poll that learns nothing
        /// new emits nothing. Cleared by `disconnect()`.
        var emitted: [ChatKit.Member.ID: ChatKit.Presence] = [:]
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

    /// Everyone in a one-to-one DM. App DMs are left out: an app has no
    /// presence to show. The local user is included when they are listed,
    /// which costs one id in the request and draws nothing.
    static func presenceTargets(in conversations: [Conversation]) -> [ChatKit.Member.ID] {
        let ids = conversations.filter { $0.kind == .directMessage }.flatMap(\.members)
        return Set(ids).sorted { $0.rawValue < $1.rawValue }
    }

    /// Starts polling for `conversations`' DM partners, replacing any poll
    /// already running - a world reload is the one place the set of people
    /// changes.
    ///
    /// **The first run waits for `names`, the world load's `get_members`.**
    /// `.setPresence` is an UPDATE and drops presence for anyone the store has
    /// no member row for, and member rows come only from that lookup. An
    /// answer that landed first would be dropped, and because `emitted`
    /// already recorded it, never sent again: on a fresh store, every dot
    /// would stay missing until that person's state changed. Awaiting a task
    /// is not cancelling it, so this cannot finish the lookup early.
    func startPresencePoll(
        for conversations: [Conversation],
        using apiClient: ProtoAPIClient,
        after names: Task<Void, Never>?
    ) {
        presencePoll.task?.cancel()
        presencePoll.task = nil
        let ids = Self.presenceTargets(in: conversations)
        guard !ids.isEmpty else { return }
        let interval = presencePollInterval
        presencePoll.task = Task { [weak self] in
            await names?.value
            while !Task.isCancelled {
                // `nil` once the backend has gone, which ends the loop rather
                // than sleeping forever on behalf of nobody.
                guard await self?.pollPresence(ids, using: apiClient) != nil else { return }
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
    func pollPresence(_ ids: [ChatKit.Member.ID], using apiClient: ProtoAPIClient) async {
        let response: GetUserPresenceResponse
        do {
            response = try await apiClient.call(.getUserPresence, Self.getUserPresenceRequest(ids))
        } catch {
            // Cancelled means a world reload or `disconnect()` replaced this
            // poll while the call was out; its failure is not news.
            guard !Task.isCancelled else { return }
            if !presencePoll.failureReported {
                presencePoll.failureReported = true
                emit(.backendError(Self.chatError(fromAPI: error, call: "the /api/ get_user_presence call")))
            }
            withdrawPresence()
            return
        }
        // After the await, for the same reason: a stale session's presence
        // must not land in the next one.
        guard !Task.isCancelled else { return }
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
    }

    /// Everything the poll has shown becomes `absentPresence`, and is
    /// forgotten so the next success shows it all again.
    ///
    /// A failed poll cannot confirm anything, and a dot is a claim about now.
    /// Without this, one success followed by any run of failures (an expired
    /// token, a server change) would leave every dot on that answer for the
    /// life of the process - with a setter and no clearer (`CLAUDE.md`, a
    /// field written by a snapshot is stale in both directions). The cost is a
    /// dot that vanishes for one interval after a transient failure.
    private func withdrawPresence() {
        for (id, presence) in presencePoll.emitted.sorted(by: { $0.key.rawValue < $1.key.rawValue })
            where presence != Self.absentPresence {
            emit(.presenceChanged(member: id, presence: Self.absentPresence))
        }
        presencePoll.emitted = [:]
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
