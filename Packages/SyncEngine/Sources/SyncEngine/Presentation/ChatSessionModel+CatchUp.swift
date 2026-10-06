import ChatKit
import Foundation

/// Split out of `ChatSessionModel.swift` for swiftlint's `file_length`, the
/// reason `+Send.swift` and `+AutoMarkRead.swift` exist. A pure move.
extension ChatSessionModel {
    /// Refetches the open conversation's history when the channel comes back.
    ///
    /// A reconnect is a fresh registration with `AID` reset, so messages
    /// delivered during the outage were never seen and no later event will
    /// replay them. The conversation *list* is handled below the seam by
    /// `.gap(scope: .everything)`; this is the half that depends on which
    /// conversation the user has open, which nothing below the seam knows.
    func catchUpIfReconnected(_ state: ConnectionState) {
        defer { actedOnConnection = state }
        guard case .connected = state else { return }
        if case .connected = actedOnConnection {
            return
        }
        guard let selected else { return }
        // The same task the selection path owns, so a selection change
        // cancels this exactly as it cancels its own fetch - and so that this
        // refetch cannot outlive a selection change of its own, clobbering a
        // fresher fetch's result with an older conversation's history.
        historyTask?.cancel()
        historyTask = Task { [engine] in
            await engine.requestMoreMessages(in: selected)
        }
        // A watch sent while disconnected was dropped, and a conversation
        // selected during launch sent one before the session existed. The
        // same holds for a member load.
        Task { [engine] in await engine.watchPresence(in: selected) }
        Task { [engine] in await engine.loadMembers(in: selected) }
    }
}
