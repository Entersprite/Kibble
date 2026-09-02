import ChatKit
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `LocalBridgeBackend.chatError(fromAPI:call:)` - the mapping every `/api/`
/// call site funnels through on the way to `ChatWindow`'s banner.
///
/// Fix round: the `call` label used to reach only `.httpStatus`'s message,
/// so a failed `get_members` and a failed `create_message` both surfaced as
/// the same unlabelled "Connection problem: transport error". These pin that
/// every branch now says which call failed, using values these tests build
/// directly rather than routing a real transport through `ProtoAPIClient` -
/// that path is already covered end to end by
/// `LoadConversationsMemberResolutionTests`.
@Suite("LocalBridgeBackend.chatError(fromAPI:)")
struct LocalBridgeBackendErrorsTests {
    @Test func anHTTPStatusNamesTheCallThatFailed() {
        let error = LocalBridgeBackend.chatError(
            fromAPI: APIFailure.httpStatus(403),
            call: "the /api/ get_members call"
        )
        #expect(error == .server(status: 403, message: "the /api/ get_members call"))
    }

    @Test func anUnclassifiedTransportFailureNamesTheCallAndStaysGeneric() {
        let error = LocalBridgeBackend.chatError(
            fromAPI: APIFailure.transport(nil),
            call: "the /api/ create_message call"
        )
        #expect(error == .transport("the /api/ create_message call: transport error"))
    }

    /// The classification travels alongside the call name, not instead of it -
    /// a person reading the banner should be able to tell both what failed
    /// and roughly why.
    @Test func aClassifiedTransportFailureNamesBothTheCallAndTheReason() {
        let error = LocalBridgeBackend.chatError(
            fromAPI: APIFailure.transport(.timedOut),
            call: "the /api/ create_topic call"
        )
        #expect(error == .transport("the /api/ create_topic call: transport error (timed out)"))
    }

    @Test func anEmptyBodyNamesTheCallThatFailed() {
        let error = LocalBridgeBackend.chatError(
            fromAPI: APIFailure.emptyBody,
            call: "the /api/ list_topics call"
        )
        #expect(error == .decoding("the /api/ list_topics call: empty body"))
    }

    /// The default label, unchanged - `loadConversations()`'s own call site
    /// still does not have to name itself explicitly.
    @Test func theDefaultCallLabelNamesPaginatedWorld() {
        let error = LocalBridgeBackend.chatError(fromAPI: APIFailure.transport(nil))
        #expect(error == .transport("the /api/ paginated_world call: transport error"))
    }

    /// The defensive fallback for an error `apiClient.call(_:_:)` cannot
    /// actually produce - see the function's own doc comment - still must
    /// not interpolate that error's description.
    @Test func anUnrecognisedErrorTypeNeverLeaksItsDescription() {
        struct Sentinel: Error, CustomStringConvertible {
            var description: String {
                "SENTINEL-DO-NOT-LEAK"
            }
        }
        let error = LocalBridgeBackend.chatError(
            fromAPI: Sentinel(),
            call: "the /api/ get_self_user_status call"
        )
        guard case let .transport(message) = error else {
            Issue.record("expected .transport, got \(error)")
            return
        }
        #expect(message.contains("the /api/ get_self_user_status call"))
        #expect(!message.contains("SENTINEL-DO-NOT-LEAK"))
    }
}
