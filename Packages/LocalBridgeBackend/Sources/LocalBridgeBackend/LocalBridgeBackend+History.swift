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
    /// A page of history, via `TopicsRequestLadder.history(for:)`: the
    /// reference's `page_size_for_topics: 50` plus `page_size_for_replies:
    /// 50`, so a thread's replies arrive with its first message (`findings.md`
    /// §63.5), and each thread's read state is emitted as `.threadChanged`
    /// (threads spec §2.2). A topic listing as many messages as the reply
    /// cap may be a longer thread cut short, so only field 10 counts it,
    /// because a count replaces the stored one; its read state is a snapshot
    /// all the same, and clears a stale mark.
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
    /// **No per-topic `list_messages` follow-up.** Replies come with the page;
    /// a thread longer than 50 replies is read whole by `loadThread(_:in:)`
    /// when its panel opens.
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
        let rung = TopicsRequestLadder.history(for: group)
        do {
            let response = try await apiClient.call(.listTopics, rung.request)
            let mapped = HistoryMapping.map(response)
            // Each thread's count, read position and mark, before the page
            // is returned, so the store has both when the transcript draws.
            // A listing that reaches the reply cap may be cut short, and
            // `.counted` replaces the stored count, so it counts only under
            // the cap; its read state is still a snapshot.
            let cap = Int(rung.request.pageSizeForReplies)
            for topic in response.topics {
                let listing = ThreadMapping.Listing.history(countIsComplete: topic.replies.count < cap)
                ThreadMapping.events(for: topic, in: conversationID, listing: listing).forEach(emit)
            }
            // Same rule `loadConversations()` follows for `WorldMapping.Result.skipped`:
            // a count, never an id or message text, rather than a silently
            // shorter array.
            if mapped.skipped > 0 {
                emit(.backendError(.unknown(
                    "\(mapped.skipped) message(s) could not be mapped and were skipped"
                )))
            }
            // Names for the senders, started rather than awaited - the same
            // rule `loadConversations()` follows for its own lookup. A space
            // lists no members on the world response (`findings.md` §37.5),
            // so without this anyone met only in a space renders as an id.
            resolveUnknownMembers(mapped.messages.map(\.sender))
            return mapped.messages
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ list_topics call")
        }
    }
}
