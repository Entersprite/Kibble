import ChatKit
import GChatBridgeCore

/// `channelStopped(_:)`, split out of `LocalBridgeBackend.swift` once fix
/// round 1's Finding 3 fix pushed that file past `swiftlint`'s `file_length` -
/// the same convention `LocalBridgeBackend+Errors.swift` and
/// `LocalBridgeBackend+SelfIdentification.swift` already established for
/// extending this actor from a second file rather than growing the first
/// indefinitely. `isConnected`, `channel`, `channelTask` and `lastFailure`'s
/// setter are not `private` in the main file specifically so this one
/// function can reach them - the same reason `apiClient` and `emit(_:)`
/// already were not private.
extension LocalBridgeBackend {
    /// Whether the long poll is running. For tests and for a host that wants to
    /// show more than the last event said.
    public var isRunningChannel: Bool {
        channelTask != nil
    }

    /// Waits for the channel to stop. Tests use it; nothing in the app should,
    /// because it returns when the session ends.
    public func waitForChannel() async {
        await channelTask?.value
    }

    /// Reached for a **terminal** failure - a dead credential
    /// (`.unexpectedStatus(401)`/`(403)`), an unrecognised status, or a
    /// framing desync (`.noSessionIdentifier`, `.malformedChunk`) - or for a
    /// deliberate `disconnect()`. Since task 3 of the reconnect taxonomy, a
    /// *recoverable* failure no longer arrives here at all:
    /// `ChannelSession` reconnects on its own for those
    /// (`ChannelFailure.isRecoverable`), and this only runs once the
    /// channel's own state machine has genuinely stopped responding. Saying
    /// nothing here would still leave a window showing a healthy session
    /// that has quietly stopped delivering, for the one case that still ends.
    ///
    /// The guard is on **identity**, not merely on there being a channel. A
    /// `disconnect()` → `connect()` sequence leaves the old task still
    /// unwinding, and its `channelStopped` arriving after the new channel is
    /// running would tear down the *new* session - `channelTask`, `channel`,
    /// `isConnected` and `apiClient` all nilled for a channel that is
    /// perfectly alive, presenting as a session that connects and instantly
    /// reports itself disconnected. Unreachable from the app as it stands,
    /// because nothing reconnects; latent, and the fix is one clause.
    /// Internal rather than private only so a test can hand it a channel that
    /// is not the current one, which is the whole condition being guarded and
    /// is otherwise a race no test could schedule. Same reason
    /// `isRunningChannel` and `waitForChannel()` exist.
    ///
    /// **`channel.failure` is guaranteed non-nil at the point this emits**
    /// (fix round 1's Finding 3/R18): the guard above means a deliberate
    /// `disconnect()` never reaches this body at all - `stopChannel()` nils
    /// `channelTask` before the channel's own task can call back in, so
    /// `channelTask != nil` always fails for that path. What's left is only a
    /// genuine terminal failure, so `ConnectionIssueMapping` can map it in
    /// one line rather than defaulting to `nil` - `ConnectionState
    /// .disconnected`'s own doc comment already states the contract
    /// (`issue` "is nil for a deliberate disconnect for the same reason
    /// `reason` is", implying non-nil otherwise), and it was previously left
    /// unfulfilled here: a `ConnectionIssue` case with no producer compiles
    /// fine and simply never fires, which is exactly the design doc's own
    /// §10 risk.
    func channelStopped(_ channel: ChannelSession) async {
        // `channelTask == nil` is a deliberate disconnect; a channel that is
        // not the current one is a straggler from a previous session.
        guard channel === self.channel, channelTask != nil else { return }
        channelTask = nil
        self.channel = nil
        isConnected = false
        apiClient = nil
        // Before the error below, not after: a lookup still in flight would
        // otherwise land a `membersResolved`, which supersedes this very
        // error in the store (`SyncReducer.supersedingStaleError`).
        forgetDirectory()
        let failure = await channel.failure
        let reason = failure.map(String.init(describing:)) ?? "the channel closed"
        let issue = failure.map(ConnectionIssueMapping.issue(for:))
        if let failure {
            let error = ChatError.transport(String(describing: failure))
            lastFailure = error
            emit(.backendError(error))
        }
        emit(.connectionStateChanged(.disconnected(reason: reason, issue: issue)))
    }

    /// The channel's own recovery, forwarded as connection state.
    ///
    /// `ConnectionState.reconnecting(attempt:)` has existed in `ChatKit` since
    /// the seam was written and has been emitted by nobody. It is what lets a
    /// window say "attempt 2" instead of spinning silently, and it needs no
    /// wire-format change to reach a hosted tier later. `failure` is what
    /// `ChannelSession` classified as the cause of this particular reconnect;
    /// `ConnectionIssueMapping` is the one place it becomes a
    /// `ChatKit.ConnectionIssue`, behind the exhaustive switch that keeps this
    /// package's copy of the taxonomy from silently drifting from the core's.
    ///
    /// Not `private`: moved out of `LocalBridgeBackend.swift` once this task's
    /// fix pushed that file past swiftlint's `file_length` ceiling, alongside
    /// `channelStopped(_:)` above - the same convention that function's own
    /// doc comment already established for this file, and passed as a
    /// callback where `LocalBridgeBackend.swift`'s `startChannel()`
    /// constructs `ChannelSession`, which is why it cannot be `private` here.
    func channelLifecycleChanged(_ event: ChannelLifecycle) {
        switch event {
        case let .reconnecting(attempt, failure):
            let issue = failure.map(ConnectionIssueMapping.issue(for:))
            emit(.connectionStateChanged(.reconnecting(
                attempt: attempt,
                issue: issue,
                detail: failure?.description
            )))
        case .resumed:
            lastFailure = nil
            emit(.connectionStateChanged(.connected))
            // `findings.md` §23.1. A reconnect is a fresh registration - a new
            // SID with `AID` reset - so events delivered during the outage are
            // gone, and the conversation list has been stale since launch
            // because nothing but `connect()` ever refetched it. Emitting the
            // same gap `connect()` does is the whole fix.
            emit(.gap(scope: .everything, reason: LocalBridgeBackend.resumedGapReason))
        }
    }
}
