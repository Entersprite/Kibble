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
    /// cap may be a longer thread cut short, and so may any topic on an
    /// anchored page (§65.9), so neither is counted, because a count replaces
    /// the stored one; its read state is a snapshot all the same, and clears
    /// a stale mark.
    ///
    /// **`before:` anchors on a time when this session mapped that message.**
    /// `list_topics` has no message cursor, but every request the web client
    /// sent carried `filter.anchor.time_usec` and `sort_option: 2`
    /// (`findings.md` §65.9), so a known `before` sends
    /// `TopicsRequestLadder.history(for:anchoredAt:)` at its own create time,
    /// to the microsecond (`messageTimes`). An unknown one, or `nil`, first
    /// sends the plain page. If that page ends before the world's newest
    /// head, a second request anchors there and merges its window. A full
    /// plain page also asks for a window at the present time: a busy space
    /// can fill all 50 topic slots before its newest message, while the
    /// world head remembered at connection time may itself be stale.
    ///
    /// The live probe measured an anchored response as a window around its
    /// time (§65.10). For backward paging, keep only messages strictly older
    /// than `before`, by microseconds. An empty filtered page stops paging;
    /// thread read states from the response are still snapshots. The
    /// latest-head retry instead keeps the whole window so the message
    /// missing from the plain page can reach the transcript.
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
            let mapped = recordHistory(
                response, in: conversationID, anchored: anchor != nil,
                replyCap: Int(rung.request.pageSizeForReplies)
            )
            var page = anchor.map { anchor in
                mapped.messages.filter { Microseconds.from($0.createdAt) < anchor }
            } ?? mapped.messages
            // A full plain page gives no assurance that it reached the most
            // recent topic. The world head is also only as fresh as the last
            // world load, so use a present-time window in that case.
            if before == nil,
               let retryAnchor = latestRetryAnchor(
                   for: conversationID, topicsCount: response.topics.count,
                   pageSize: Int(rung.request.pageSizeForTopics), messages: page
               ) {
                do {
                    let retry = TopicsRequestLadder.history(for: group, anchoredAt: retryAnchor)
                    let answer = try await apiClient.call(.listTopics, retry.request)
                    let newer = recordHistory(
                        answer, in: conversationID, anchored: true,
                        replyCap: Int(retry.request.pageSizeForReplies)
                    )
                    page = Self.merged(page, newer.messages)
                } catch {
                    // The first page still has useful history. Report the
                    // failed retry without discarding what already loaded.
                    emit(.backendError(Self.chatError(
                        fromAPI: error,
                        call: "the newest /api/ list_topics call"
                    )))
                }
            }
            // Resolve only senders in messages the caller will store. An
            // anchored backward page may have returned newer messages that
            // its strict older-than filter deliberately leaves out.
            resolveUnknownMembers(page.map(\.sender))
            return page
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ list_topics call")
        }
    }

    private static func newestMainMessage(in messages: [ChatKit.Message]) -> Int64 {
        messages.lazy.filter { !$0.isReply }.map { Microseconds.from($0.createdAt) }.max() ?? 0
    }

    private func latestRetryAnchor(
        for conversation: Conversation.ID, topicsCount: Int, pageSize: Int, messages: [ChatKit.Message]
    ) -> Int64? {
        let head = conversationHeads[conversation]
        if topicsCount >= pageSize {
            return max(Microseconds.from(Date()), head ?? 0)
        }
        if let head, Self.newestMainMessage(in: messages) < head {
            return head
        }
        return nil
    }

    private static func merged(_ first: [ChatKit.Message], _ second: [ChatKit.Message]) -> [ChatKit.Message] {
        var byID: [ChatKit.Message.ID: ChatKit.Message] = [:]
        for message in first + second {
            byID[message.id] = message
        }
        return byID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id.rawValue < $1.id.rawValue : $0.createdAt < $1.createdAt
        }
    }

    private func recordHistory(
        _ response: ListTopicsResponse, in conversationID: Conversation.ID, anchored: Bool, replyCap: Int
    ) -> HistoryMapping.Result {
        let mapped = HistoryMapping.map(response)
        messageTimes.remember(mapped.messages)
        // An anchored window may cut a topic's replies short, so it cannot
        // replace a complete thread count. Its read state is still a snapshot.
        for topic in response.topics {
            let complete = !anchored && topic.replies.count < replyCap
            let listing = ThreadMapping.Listing.history(countIsComplete: complete)
            ThreadMapping.events(for: topic, in: conversationID, listing: listing).forEach(emit)
        }
        if mapped.skipped > 0 {
            emit(.backendError(.unknown("\(mapped.skipped) message(s) could not be mapped and were skipped")))
        }
        return mapped
    }
}
