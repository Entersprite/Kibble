import Foundation
import Testing
@testable import GChatBridgeCore

struct ConversationActionRequestsTests {
    private var dm: GroupId {
        var value = GroupId()
        var id = DmId()
        id.dmID = "d"
        value.dmID = id
        return value
    }

    @Test func unreadUsesTheNativeGroupAndExplicitTimestamp() throws {
        let request = ConversationActionRequests.unread(group: dm, micros: 1_790_000_000_000_001)
        #expect(request.hasRequestHeader)
        #expect(request.groupID == dm)
        #expect(request.unreadTimestamp == 1_790_000_000_000_001)
        #expect(try ProtoFieldScan.fields(in: request.serializedData()).fields.map(\.number).sorted() == [
            1,
            2,
            100
        ])
        let clear = ConversationActionRequests.unread(group: dm, micros: 0)
        #expect(clear.hasUnreadTimestamp && clear.unreadTimestamp == 0)
    }

    @Test func deletionUsesClearHistoryAndANumericTimestamp() throws {
        let call = try ConversationActionRequests.clearHistory(group: dm, micros: 1_790_000_000_000_001)
        #expect(call.rpc == "azPJGe")
        #expect(call.payload == #"[["dm/d","d",5],1790000000000001]"#)
    }

    @Test func hideIsExplicitAndBlockDoesNotReport() {
        let hide = ConversationActionRequests.hide(group: dm)
        #expect(hide.id == dm && hide.hasHide && hide.hide)
        var user = UserId()
        user.id = "other"
        let block = ConversationActionRequests.block(group: dm, user: user)
        #expect(block.userID == user && block.hasBlocked && block.blocked)
        #expect(block.hasReported && !block.reported)
        let groupBlock = ConversationActionRequests.block(group: dm, user: nil)
        #expect(groupBlock.groupID == dm)
    }

    @Test func leaveNamesOnlyTheCurrentMember() {
        var user = UserId()
        user.id = "me"
        var member = MemberId()
        member.userID = user
        let request = ConversationActionRequests.leave(group: dm, member: member)
        #expect(request.groupID == dm)
        #expect(request.memberIds == [member])
        #expect(!request.hasMembershipState)
    }
}
