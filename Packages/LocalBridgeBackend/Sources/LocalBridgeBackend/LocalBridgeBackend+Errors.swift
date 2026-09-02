import ChatKit
import GChatBridgeCore

/// Translating the core's failures onto the domain's error vocabulary.
///
/// Split out of `LocalBridgeBackend.swift` once `resolveAndEmitMembers`
/// pushed that file past `swiftlint`'s `file_length` - the same convention
/// `LocalBridgeBackend+Capture.swift` already established for extending this
/// actor from a second file rather than growing the first indefinitely.
extension LocalBridgeBackend {
    /// Maps a bootstrap failure onto the domain's error vocabulary.
    ///
    /// The distinctions are the point. A previous session spent three cookie
    /// captures on what turned out to be a rejected *client*, because every
    /// failure on this protocol arrives as HTTP 200 and the diagnosis had been
    /// flattened to "your credentials are bad".
    static func chatError(from error: any Error) -> ChatError {
        if let error = error as? ChatError {
            return error
        }
        guard let failure = error as? BootstrapFailure else {
            return .transport(String(describing: error))
        }
        switch failure {
        case .signInRedirect:
            return .notAuthenticated
        case let .unsupportedClient(url):
            // Not a credentials problem: the session authenticated and the
            // client was refused. Naming the browser is what stops the next
            // person re-capturing cookies that were fine.
            return .transport("Chat rejected this client as an unsupported browser (\(url.path))")
        case let .unexpectedStatus(status):
            return .server(status: status, message: "the Chat shell")
        case let .noGlobalData(diagnosis):
            // Carries no page content - the diagnosis is counts, a status and a
            // capped title, which is deliberate, because a signed-in shell has
            // real names and messages in it.
            return .unknown(String(describing: diagnosis))
        }
    }

    static func reason(for error: ChatError) -> String {
        switch error {
        case .notAuthenticated, .sessionExpired: "not signed in"
        default: "could not reach Chat"
        }
    }

    /// Maps an `/api/` call's failure onto the domain's error vocabulary.
    ///
    /// **There is deliberately no `.notAuthenticated` case here**, mirroring
    /// `APIFailure`'s own doc comment: whether `/api/` answers a dead session
    /// the way the Chat shell does (HTTP 200 plus a sign-in page, per §13) is
    /// unrecorded - no run has put an expired credential in front of it.
    /// Guessing either way would promote a guess to a policy.
    ///
    /// `call` names which `/api/` call failed, and now reaches every branch's
    /// message, not just `.httpStatus`'s - a banner that only ever said
    /// "Connection problem: transport error" left nobody able to tell a
    /// failed `get_members` from a failed `create_message`. Defaulted to
    /// `loadConversations()`'s own call so its existing call site did not
    /// need to change when `resolveAndEmitMembers` became a second caller
    /// with a different call to name.
    static func chatError(
        fromAPI error: any Error,
        call: String = "the /api/ paginated_world call"
    ) -> ChatError {
        guard let failure = error as? APIFailure else {
            // `apiClient.call(_:_:)` only ever throws `APIFailure` - see
            // `TopicsRequestLadder.swift`'s and `WorldRequestLadder.swift`'s
            // own comments on the same fact - so this is a defensive
            // fallback for a case that should not occur, not a path any test
            // exercises through a real call site. It still must not
            // interpolate `error` itself: an error escaping the transport
            // and decoding layers untyped is exactly the kind this function
            // exists to keep off the banner.
            return .transport("\(call): an unrecognised error type")
        }
        switch failure {
        case let .httpStatus(status):
            return .server(status: status, message: call)
        case .transport:
            return .transport("\(call): \(failure.safeDescription)")
        case .emptyBody, .undecodable:
            return .decoding("\(call): \(failure.safeDescription)")
        }
    }
}
