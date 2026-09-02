import ChatKit
import Foundation
import GChatBridgeCore

/// `ListTopicsResponse` becoming `[ChatKit.Message]`.
///
/// The protocol model, from the reference (`mautrix_googlechat/portal.py:406-446`):
/// a group has topics, each `Topic` carries `replies` (repeated `Message`),
/// and **in a flat group every message is its own topic** - `findings.md`
/// §20.4 observed `flat_group` on all four of this account's conversations
/// and `threaded_group` on none, so `list_topics` alone should carry the
/// whole history for this account without the threaded-reply `list_messages`
/// follow-up (`APIMethod.listMessages`, declared and never sent).
///
/// ## Reuse, not a second translation
///
/// Every reply is a wire `Message`, translated through
/// `ChannelEventMapping.domainMessage(_:)` - the exact function
/// `MESSAGE_POSTED`/`MESSAGE_UPDATED` already use, including its
/// microsecond-string `create_time` handling (`findings.md` §2.3). Writing a
/// second translation here would be the same defect a reviewer already
/// caught once on this branch, and it would let the channel and history
/// silently drift apart on timestamps.
///
/// ## Topics arrive reversed
///
/// The reference does not trust `list_topics`'s own ordering: it re-sorts
/// `reversed(resp.topics)` by `sort_time` before replaying them
/// (`portal.py:428`). This mirrors that by sorting every mapped message
/// **ascending by its own mapped `createdAt`** - on the message itself rather
/// than on arrival order or on the topic's `sort_time`, because
/// `ChatBackend.loadMessages(in:before:)`'s own contract is "oldest-to-newest"
/// on the messages it returns, and trusting arrival order is exactly the kind
/// of assumption `findings.md` keeps recording as wrong.
///
/// ## Nothing is silently dropped
///
/// A reply whose `id.message_id` is empty, or whose `id.parent_id.topic_id.group_id`
/// cannot become a `Conversation.ID`, is not a message this mapping can place
/// - `domainMessage(_:)` returns `nil` for exactly those cases rather than
/// fabricating an identity. It is still real data the server sent, and
/// folding it into a shorter `messages` array with no trace would be the same
/// kind of silent loss `WorldMapping.Result.skipped` and
/// `MemberMapping.Result.skipped` both exist to prevent.
public enum HistoryMapping {
    /// A mapped page of history, plus what could not be placed.
    public struct Result: Sendable, Hashable {
        public let messages: [ChatKit.Message]

        /// How many replies did not become a `ChatKit.Message`, counted
        /// separately from `messages.count` for the same reason
        /// `WorldMapping.Result.skipped` is: a caller can tell "the server
        /// sent fewer" from "some were unplaceable".
        public let skipped: Int

        public init(messages: [ChatKit.Message], skipped: Int) {
            self.messages = messages
            self.skipped = skipped
        }
    }

    public static func map(_ response: ListTopicsResponse) -> Result {
        var messages: [ChatKit.Message] = []
        var skipped = 0
        for topic in response.topics {
            for reply in topic.replies {
                guard let message = ChannelEventMapping.domainMessage(reply) else {
                    skipped += 1
                    continue
                }
                messages.append(message)
            }
        }
        // `sorted(by:)` is stable since Swift 5, so two replies that mapped to
        // the exact same `createdAt` keep their relative order rather than
        // being shuffled by the sort.
        let ordered = messages.sorted { $0.createdAt < $1.createdAt }
        return Result(messages: ordered, skipped: skipped)
    }
}
