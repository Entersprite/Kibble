import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct ConversationActionMappingTests {
    @Test func manualUnreadAndClearDecodeStringTimestamps() {
        let marked = ChannelEventBody(typeTag: 37, value: .object([
            "32": [[nil, nil, ["a"]], "1790000000000001"]
        ]))
        let cleared = ChannelEventBody(typeTag: 37, value: .object(["32": [[nil, nil, ["a"]], "0"]]))
        #expect(ChannelEventMapping.conversationActionEvent(in: marked) == .conversationUnreadMarkChanged(
            conversationID: Conversation.ID("dm/a"), at: Microseconds.date(1_790_000_000_000_001)
        ))
        #expect(ChannelEventMapping.conversationActionEvent(in: cleared) == .conversationUnreadMarkChanged(
            conversationID: Conversation.ID("dm/a"), at: nil
        ))
    }

    @Test func hidingAndClearingHistoryAreDifferentEvents() {
        let hidden = ChannelEventBody(typeTag: 16, value: .object(["15": [[nil, nil, ["a"]], true]]))
        let deleted = ChannelEventBody(typeTag: 32, value: .object([
            "29": [[nil, nil, ["a"]], "1790000000000001", true]
        ]))
        #expect(ChannelEventMapping.conversationActionEvent(in: hidden) == .conversationRemoved(
            conversationID: Conversation.ID("dm/a"), historyBefore: nil
        ))
        #expect(ChannelEventMapping.conversationActionEvent(in: deleted) == .conversationRemoved(
            conversationID: Conversation.ID("dm/a"), historyBefore: Microseconds.date(1_790_000_000_000_001)
        ))
    }

    @Test func aWorldItemMarkedUnreadIsUnreadEvenIfItsHeadWasRead() {
        var item = WorldItemFixture.item(
            groupID: WorldItemFixture.dmGroupID("a"),
            lastReadMicros: 100,
            newestMessageMicros: 100
        )
        item.readState.markAsUnreadTimestampUsec = 99
        #expect(WorldItemFixture.mapped(item)?.hasUnread == true)
        #expect(WorldItemFixture.mapped(item)?.markedUnreadAt == Microseconds.date(99))
    }

    @Test func hiddenBlockedAndDepartedItemsAreAbsentFromTheSidebar() {
        var item = WorldItemFixture.item(groupID: WorldItemFixture.dmGroupID("a"))
        item.readState.blocked = true
        #expect(WorldItemFixture.mapped(item) == nil)
        item.readState.blocked = false
        item.readState.visibleInWorldView = false
        #expect(WorldItemFixture.mapped(item) == nil)
        item.readState.visibleInWorldView = true
        item.readState.membershipState = .memberNotAMember
        #expect(WorldItemFixture.mapped(item) == nil)
    }
}
