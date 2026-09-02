import Foundation
import SwiftProtobuf

/// One `/api/` method, with its request and response types attached.
///
/// The type parameters are phantoms - nothing is stored but the name - and that
/// is the whole point: `call(.getSelfUserStatus, request)` cannot be handed the
/// wrong request type, and its return type needs no annotation at the call
/// site. On a protocol with dozens of near-identically-named messages, that is
/// worth more than it looks.
public struct APIMethod<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable
>: Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

// MARK: - The methods this build knows

public extension APIMethod where Request == GetSelfUserStatusRequest, Response == GetSelfUserStatusResponse {
    /// The **one** `/api/` call verified end to end against live traffic
    /// (`findings.md` §3.6): HTTP 200, and a response that decoded into named
    /// fields. Everything else in this file is a shape, not a finding.
    static var getSelfUserStatus: Self {
        Self("get_self_user_status")
    }
}

public extension APIMethod where Request == PaginatedWorldRequest, Response == PaginatedWorldResponse {
    /// The conversation list. **The minimum viable request shape is answered**
    /// - `findings.md` §20.1: `request_header` + `fetch_from_user_spaces` +
    /// one `WorldSectionRequest(page_size: 999)`, which is
    /// `WorldRequestLadder.minimumViable`.
    /// `WorldMapping` builds `[Conversation]` from what this returns; what is
    /// still `[Verify]` (§20.4) is which fields *inside* one `WorldItemLite`
    /// are populated - the ladder's scan was top-level only.
    static var paginatedWorld: Self {
        Self("paginated_world")
    }
}

public extension APIMethod where Request == ListTopicsRequest, Response == ListTopicsResponse {
    /// History for one conversation - `TopicsRequestLadder` builds the four
    /// candidate shapes and `HistoryMapping` (in `LocalBridgeBackend`) turns
    /// what comes back into `[ChatKit.Message]`. **Never yet sent by this
    /// implementation.** Same posture `paginatedWorld`'s doc comment held
    /// before `findings.md` §20.1's live run answered which shape actually
    /// works - a request built from the proto and the reference
    /// (`mautrix_googlechat/portal.py:406-446`), not yet confirmed against
    /// live traffic.
    static var listTopics: Self {
        Self("list_topics")
    }
}

public extension APIMethod where Request == ListMessagesRequest, Response == ListMessagesResponse {
    /// The threaded-reply follow-up `portal.py:428-436` sends per topic, only
    /// when a group is threaded or `topic.topic_read_state.thread_created_usec
    /// > 0`. **Declared and never sent.** `findings.md` §20.4 observed
    /// `flat_group` on all four of this account's conversations and
    /// `threaded_group` on none, so exercising this call would be untestable
    /// guesswork against an account that cannot reach the threaded branch.
    static var listMessages: Self {
        Self("list_messages")
    }
}

public extension APIMethod where Request == GetMembersRequest, Response == GetMembersResponse {
    /// Member names, keyed by `MemberId`. **Never yet sent by this
    /// implementation.** `paginated_world` carries no names at all
    /// (`findings.md` §20.4: `room_name`, `name_users` and `avatar_url` are
    /// all absent from a live `WorldItemLite`), so this is the reference's
    /// separate call for resolving them - `client.py:691-697`. Its response
    /// shape is `[Verify]` in the same sense §20.4 flags `WorldItemLite`:
    /// field numbers confirmed against the vendored proto, never observed on
    /// the wire.
    static var getMembers: Self {
        Self("get_members")
    }
}
