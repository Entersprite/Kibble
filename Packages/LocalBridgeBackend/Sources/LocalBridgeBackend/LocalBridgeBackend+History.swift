import ChatKit
import Foundation
import GChatBridgeCore

/// History for one conversation - `loadMessages(in:before:)`.
///
/// Split into its own file for the same reason `+Directory.swift`,
/// `+Errors.swift`, `+SelfIdentification.swift` and `+Capture.swift` already
/// are: `swiftlint`'s `file_length`, and this is a coherent concern of its
/// own rather than an arbitrary cut.
public extension LocalBridgeBackend {
    /// A page of history, via `TopicsRequestLadder.minimumViable(for:)` -
    /// `request_header` + `group_id` + `page_size_for_topics: 50`, the
    /// reference's own shape (`mautrix_googlechat/portal.py:408-416`).
    ///
    /// **`[Verify]`: no rung of `TopicsRequestLadder` has ever been sent
    /// against live traffic.** `list_topics` has never been sent by anything
    /// in this project, in any language - `findings.md` has no §20.1-style
    /// live-run entry for it yet, the same posture `WorldMapping` correctly
    /// held toward `WorldItemLite` before that section's run. Read
    /// `TopicsRequestLadder.minimumViable(for:)`'s own doc comment before
    /// trusting this shape.
    ///
    /// **`before:` is ignored, and pagination is unimplemented.** The
    /// vendored `ListTopicsRequest` has no cursor or offset field - only
    /// `user_not_older_than` / `group_not_older_than` *revisions*
    /// (`ReferenceRevision`), which `ChatBackend.loadMessages(in:before:)`'s
    /// own `[Verify]` comment already flags as an open question about
    /// whether `before:` should even stay a message-id cursor. Inventing a
    /// cursor out of a revision nobody has verified would be worse than
    /// admitting there is not one yet, so this always returns the first page.
    ///
    /// **The threaded-reply follow-up is not attempted.** The reference sends
    /// a `list_messages` call per topic when a group is threaded or
    /// `topic.topic_read_state.thread_created_usec > 0`
    /// (`portal.py:428-436`); `findings.md` §20.4 observed every conversation
    /// on this account is flat, so exercising that path would be untestable
    /// guesswork. `APIMethod.listMessages` is declared and never sent.
    ///
    /// This is the one package that imports both the domain and the
    /// generated protobuf, and the protobuf has a `Message` of its own -
    /// every domain type whose name the wire also uses has to be qualified
    /// here, the same cost `LocalBridgeBackend+Directory.swift` already pays.
    func loadMessages(
        in conversationID: Conversation.ID,
        before _: ChatKit.Message.ID?
    ) async throws -> [ChatKit.Message] {
        guard let apiClient else {
            throw ChatError.unknown(
                "loadMessages(in:before:) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        guard let group = ChannelEventMapping.groupID(for: conversationID) else {
            throw ChatError.unknown(
                "\(conversationID.rawValue) has neither the space/ nor the dm/ prefix "
                    + "this backend produces, so no list_topics request can be built for it"
            )
        }
        let rung = TopicsRequestLadder.minimumViable(for: group)
        do {
            let response = try await apiClient.call(.listTopics, rung.request)
            let mapped = HistoryMapping.map(response)
            // Same rule `loadConversations()` follows for `WorldMapping.Result.skipped`:
            // a count, never an id or message text, rather than a silently
            // shorter array.
            if mapped.skipped > 0 {
                emit(.backendError(.unknown(
                    "\(mapped.skipped) message(s) could not be mapped and were skipped"
                )))
            }
            return mapped.messages
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ list_topics call")
        }
    }
}
