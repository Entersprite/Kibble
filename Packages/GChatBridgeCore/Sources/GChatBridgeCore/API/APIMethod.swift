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

public extension APIMethod where Request == GetUserPresenceRequest, Response == GetUserPresenceResponse {
    /// Whether people are active, away or on do not disturb. **Never yet sent
    /// by this implementation.** The reference polls it rather than waiting to
    /// be told: purple asks every 120 seconds, and its handler for the
    /// channel's `USER_STATUS_UPDATED_EVENT` notes that event carries DND but
    /// not active/inactive (`googlechat_events.c`, "fetch presence separately
    /// from status"). Request and response field numbers agree across all
    /// three vendored protos; the response shape is `[Verify]` until a probe
    /// run.
    static var getUserPresence: Self {
        Self("get_user_presence")
    }
}

public extension APIMethod where Request == GetMembershipRequest, Response == GetMembershipResponse {
    /// Is one person in one space (`findings.md` §58.3)? **Seen from the web
    /// client, never yet sent from here**: `[Verify]`.
    static var getMembership: Self {
        Self("get_membership")
    }
}

public extension APIMethod where Request == ListMembersRequest, Response == ListMembersResponse {
    /// A space's members, by id (`findings.md` §56.1). **Seen from the web
    /// client, never yet sent from here**: `[Verify]` until a probe run.
    static var listMembers: Self {
        Self("list_members")
    }
}

public extension APIMethod where Request == GetUserStatusRequest, Response == GetUserStatusResponse {
    /// Other people's `UserStatus`. **Probe only, never yet sent.** purple
    /// declares it (`googlechat_connection.h:88`) and never calls it; the
    /// in-a-meeting spike asks it as a second place a status may travel.
    static var getUserStatus: Self {
        Self("get_user_status")
    }
}

public extension APIMethod where Request == CreateTopicRequest, Response == CreateTopicResponse {
    /// Posting a new message. **The first write this client has ever made.**
    ///
    /// Every other method in this file reads. That difference is why
    /// `SendRequests` has no ladder: a wrong read shape costs a round trip, a
    /// wrong write shape costs somebody a message in a real conversation.
    /// Shape from `mautrix_googlechat/maugclib/client.py:459-470`, `[Verify]`
    /// until a deliberate single send confirms it.
    static var createTopic: Self {
        Self("create_topic")
    }
}

public extension APIMethod where Request == CreateMessageRequest, Response == CreateMessageResponse {
    /// Replying inside an existing thread - `client.py:441-457`. **Declared and
    /// unexercised**, for the same reason `listMessages` is: `findings.md`
    /// §20.4 observed `flat_group` on all four of this account's conversations
    /// and `threaded_group` on none, so nothing here can reach this branch.
    static var createMessage: Self {
        Self("create_message")
    }
}

public extension APIMethod where Request == MarkGroupReadstateRequest,
    Response == MarkGroupReadstateResponse {
    /// Publishing this client's read position. **The second write this client
    /// has ever made**, after `createTopic`.
    ///
    /// `ReadStateRequests.markGroupRead` builds it and has no ladder, for the
    /// reason stated there. `[Verify]` until one deliberate call against a
    /// live account confirms the shape - the response carries a
    /// `GroupReadState` whose `unread_message_count` is what the client then
    /// displays, so a wrong shape shows up as a badge that never clears
    /// rather than as an error.
    static var markGroupReadstate: Self {
        Self("mark_group_readstate")
    }
}

public extension APIMethod where Request == UpdateReactionRequest, Response == UpdateReactionResponse {
    /// Adding or removing one reaction - `ReactionRequests.updateReaction`.
    /// `purple` declares it (`googlechat_connection.h:110`) and never calls
    /// it; `maugclib` does (`client.py:754-759`). `[Verify]` until a live run.
    static var updateReaction: Self {
        Self("update_reaction")
    }
}

public extension APIMethod where Request == EditMessageRequest, Response == EditMessageResponse {
    /// Editing one of the person's own messages - `MessageEditRequests`.
    /// `purple` declares it (`googlechat_connection.h:115`); `maugclib` calls
    /// it (`client.py:769-773`). `[Verify]` until `--probe=edit` runs.
    static var editMessage: Self {
        Self("edit_message")
    }
}

public extension APIMethod where Request == DeleteMessageRequest, Response == DeleteMessageResponse {
    /// Deleting one of the person's own messages. `maugclib` calls it
    /// (`client.py:762-766`); a capture saw Chat on the web send it
    /// (`findings.md` §58.4). `[Verify]` until `--probe=edit` runs.
    static var deleteMessage: Self {
        Self("delete_message")
    }
}
