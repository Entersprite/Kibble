import ChatKit
import Foundation
import GChatBridgeCore

/// The conversation list. Split out of `LocalBridgeBackend.swift` for
/// swiftlint's `file_length`, the same reason `+Send.swift` exists. A pure
/// move: nothing here changed when it arrived.
public extension LocalBridgeBackend {
    /// The conversation list, via the one request shape `findings.md` §20.1
    /// proved works: `request_header` + `fetch_from_user_spaces` + one
    /// `WorldSectionRequest(page_size: 999)` - `WorldRequestLadder.minimumViable`.
    ///
    /// **Requires `connect()` to have already succeeded.** Without it there is
    /// no verified session and no xsrf token, and sending a `/api/` request
    /// with neither would not be a real attempt - it would be a request known
    /// in advance to fail, dressed up as one that tried.
    func loadConversations() async throws -> [Conversation] {
        guard let apiClient else {
            throw ChatError.unknown(
                "loadConversations() requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        let rung = WorldRequestLadder.minimumViable
        do {
            let response = try await apiClient.call(.paginatedWorld, rung.request)
            let mapped = WorldMapping.map(response)
            // `ChatBackend.loadConversations()` returns `[Conversation]` and
            // cannot carry `.skipped` alongside it, but silently returning a
            // shorter array is exactly the kind of loss `WorldMapping.Result`
            // exists to prevent - a count, never an id or a name, reaches the
            // store the UI observes instead of vanishing between two layers
            // that each assumed the other reported it.
            if mapped.skipped > 0 {
                emit(.backendError(.unknown(
                    "\(mapped.skipped) conversation(s) could not be mapped and were skipped"
                )))
            }
            // **Started, not awaited.** `SyncEngine` writes the conversations
            // to the store only once this returns, so awaiting the name lookup
            // would hold the entire sidebar behind it - and `get_members` has
            // never been sent by this implementation, carries a 30-second
            // timeout, and is exactly the wrong call to bet a first render on.
            //
            // Names arrive afterwards as `membersChanged`, which the store
            // already reduces and the views already observe. Ids first and
            // names a moment later is what the observation path is for; an
            // empty sidebar for thirty seconds is not.
            //
            // It also cannot throw by construction, so a failed name lookup can
            // never be mistaken for the world call failing and turn a degraded
            // sidebar into an empty one - the bug this package's own history
            // records as "exactly what an empty sidebar and no error message
            // looked like".
            memberResolution?.cancel()
            memberResolution = Task { [weak self] in
                await self?.resolveAndEmitMembers(for: mapped.conversations, using: apiClient)
            }
            // Started, not awaited, for the same reasons. Its first request
            // waits for the name lookup above - `startPresencePoll` says why.
            startPresencePoll(using: apiClient, after: memberResolution)
            // The same, and it also waits for the local user's own lookup.
            startCalendarPoll(for: mapped.conversations, after: [memberResolution, selfIdentification])
            return mapped.conversations
        } catch {
            throw Self.chatError(fromAPI: error)
        }
    }
}
