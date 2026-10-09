import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Which message is a reply, and what a topic's read state says about its
/// thread (threads spec §2.2). Ids and times invented; field numbers from the
/// merged proto (Task 2).
struct ThreadMappingTests {
    private let conversation = Conversation.ID("space/s-1")

    private func group() -> GroupId {
        var space = SpaceId()
        space.spaceID = "s-1"
        var group = GroupId()
        group.spaceID = space
        return group
    }

    private func message(
        _ id: String, topic: String = "t-1", inlineReply: Bool? = nil, micros: Int64 = 1_700_000_000_000_000
    ) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = topic
        message.id.parentID.topicID.groupID = group()
        message.creator.userID.id = "u-1"
        message.createTime = micros
        if let inlineReply {
            message.isInlineReply = inlineReply
        }
        return message
    }

    // MARK: - isReply

    @Test func fieldThirtyFourDecides() {
        #expect(ThreadMapping.isReply(message("r-1", inlineReply: true)))
        #expect(!ThreadMapping.isReply(message("r-1", inlineReply: false)))
    }

    /// Without field 34, a reply is a message whose id is not its topic's
    /// (§63.3: the topic is named after its first message).
    @Test func withoutItTheIdsDecide() {
        #expect(ThreadMapping.isReply(message("r-1", topic: "t-1")))
        #expect(!ThreadMapping.isReply(message("t-1", topic: "t-1")))
        #expect(!ThreadMapping.isReply(message("r-1", topic: "")))
    }

    /// History, pushes and `list_messages` all build their messages here.
    @Test func theDomainMessageCarriesIt() throws {
        let reply = try #require(ChannelEventMapping.domainMessage(message("r-1", inlineReply: true)))
        let first = try #require(ChannelEventMapping.domainMessage(message("t-1")))
        #expect(reply.isReply)
        #expect(!first.isReply)
    }

    // MARK: - events(for:in:)

    private func topic(
        _ messages: [GChatBridgeCore.Message], lastRead: Int64? = nil, markedUnread: Int64? = nil,
        unread: Int64? = nil, total: Int32? = nil
    ) -> Topic {
        var topic = Topic()
        topic.id.topicID = "t-1"
        topic.id.groupID = group()
        topic.replies = messages
        var state = TopicReadState()
        if let lastRead {
            state.lastReadTime = lastRead
        }
        if let markedUnread {
            state.markTopicAsUnreadTime = markedUnread
        }
        if let unread {
            state.unreadMessageCount = unread
        }
        if let total {
            state.totalMessageCount = total
        }
        topic.topicReadState = state
        return topic
    }

    private func changes(
        _ topic: Topic, listing: ThreadMapping.Listing = .history(countIsComplete: true)
    ) -> [ThreadChange] {
        ThreadMapping.events(for: topic, in: conversation, listing: listing).compactMap {
            if case let .threadChanged(threadID, conversationID, change) = $0,
               threadID == MessageThread.ID("t-1"), conversationID == conversation {
                change
            } else {
                nil
            }
        }
    }

    /// 652 of 713 topics in §64.7 had one message: nothing to say.
    @Test func aSingleMessageTopicSaysNothing() {
        #expect(changes(topic([message("t-1")], lastRead: 5)).isEmpty)
    }

    @Test func aThreadSaysItsCountReadPositionAndMark() {
        let thread = topic(
            [message("t-1"), message("r-1", inlineReply: true), message("r-2", inlineReply: true)],
            lastRead: 1_700_000_000_000_000, markedUnread: 1_700_000_000_500_000
        )
        #expect(changes(thread) == [
            .counted(messages: 3, unread: nil),
            .read(upTo: Date(timeIntervalSince1970: 1_700_000_000)),
            .markedUnread(at: Date(timeIntervalSince1970: 1_700_000_000.5))
        ])
    }

    /// History's read state is a snapshot: no field 14 clears a mark set
    /// elsewhere (ruling 3).
    @Test func noMarkClearsTheMark() {
        let thread = topic([message("t-1"), message("r-1", inlineReply: true)])
        #expect(changes(thread) == [.counted(messages: 2, unread: nil), .markedUnread(at: nil)])
    }

    /// A history listing that may have been cut short counts nothing, and
    /// its read state is a snapshot all the same (rulings 3 and 6).
    @Test func anIncompleteHistoryCountStillClearsTheMark() {
        let thread = topic([message("t-1"), message("r-1", inlineReply: true)])
        #expect(changes(thread, listing: .history(countIsComplete: false)) == [.markedUnread(at: nil)])
    }

    /// Field 4 is not trusted until §64.9 says it is the count.
    @Test func fieldFourIsNotTheUnreadCountYet() {
        #expect(!ThreadMapping.unreadCountIsField4)
        let thread = topic([message("t-1"), message("r-1", inlineReply: true)], unread: 1)
        #expect(changes(thread).first == .counted(messages: 2, unread: nil))
    }

    @Test func fieldTenWinsOverTheListedCount() {
        let thread = topic([message("t-1"), message("r-1", inlineReply: true)], total: 9)
        #expect(changes(thread).first == .counted(messages: 9, unread: nil))
    }

    /// The Threads list carries one reply per topic: no count from that
    /// (ruling 2). Field 10 still counts.
    @Test func aPartialListCountsNothingWithoutFieldTen() {
        let listed = [message("t-1"), message("r-1", inlineReply: true)]
        #expect(changes(topic(listed, lastRead: 5), listing: .threadsList).allSatisfy {
            if case .counted = $0 {
                false
            } else {
                true
            }
        })
        let counted = changes(topic(listed, total: 9), listing: .threadsList)
        #expect(counted.first == .counted(messages: 9, unread: nil))
    }

    /// The Threads list carries no read state (Task 5, ruling 2) and loads
    /// after every world load, so it never clears a mark: it sets one only
    /// when field 14 is present and above zero (ruling 3).
    @Test func theThreadsListOnlyEverSetsAMark() {
        let listed = [message("t-1"), message("r-1", inlineReply: true)]
        #expect(changes(topic(listed), listing: .threadsList).isEmpty)
        #expect(changes(topic(listed, markedUnread: 0), listing: .threadsList).isEmpty)
        #expect(changes(topic(listed, markedUnread: 1_700_000_000_500_000), listing: .threadsList)
            == [.markedUnread(at: Date(timeIntervalSince1970: 1_700_000_000.5))])
    }
}
