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
    /// **`before:` anchors on a time when this session mapped that message.**
    /// `list_topics` has no message cursor, but every request the web client
    /// sent carried `filter.anchor.time_usec` and `sort_option: 2`
    /// (`findings.md` §65.9), so a known `before` sends
    /// `TopicsRequestLadder.history(for:anchoredAt:)` at its own create time,
    /// to the microsecond (`messageTimes`). An unknown one, or `nil`, sends
    /// the newest page, as history always did.
    ///
    /// **Whether the server pages from the anchor is `[Verify]`.** In the
    /// capture every answer still reached the newest topic (§65.9: the anchor
    /// was the read position each time), so this never trusts it to:
    /// an anchored page returns only messages created strictly before
    /// `before`, by microseconds. If the server ignores the anchor, an old
    /// `before` gets the newest page back, filtered to nothing, and a caller
    /// paging back stops for want of progress. The threads the answer
    /// listed still report their state, filtered or not: that is a snapshot
    /// of the server's, whatever this page keeps. `--probe=search`'s anchor
    /// stage sends the same request, and its run settles the question.
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
        before: ChatKit.Message.ID?
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
        let anchor = before.flatMap { messageTimes.micros(of: $0) }
        let rung = anchor.map { TopicsRequestLadder.history(for: group, anchoredAt: $0) }
            ?? TopicsRequestLadder.history(for: group)
        do {
            let response = try await apiClient.call(.listTopics, rung.request)
            let mapped = HistoryMapping.map(response)
            // Every message mapped, kept or not: its time is a fact either way.
            messageTimes.remember(mapped.messages)
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
            let page = anchor.map { anchor in
                mapped.messages.filter { Microseconds.from($0.createdAt) < anchor }
            } ?? mapped.messages
            // Names for the senders, started rather than awaited - the same
            // rule `loadConversations()` follows for its own lookup. A space
            // lists no members on the world response (`findings.md` §37.5),
            // so without this anyone met only in a space renders as an id.
            resolveUnknownMembers(page.map(\.sender))
            return page
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ list_topics call")
        }
    }
}
