import ChatKit
import Foundation
import Testing
@testable import ChatService

struct PendingManagementReadTests {
    let id = Conversation.ID("space")
    let peer = Member(id: .init("peer"), kind: .human)

    @Test func unrelatedTrafficCannotExhaustAnInfoRead() {
        var read = PendingManagementRead(conversation: id, baseline: nil)
        for index in 0 ..< 20 {
            read.observe(.conversationUpdated(Conversation(id: .init("other-\(index)"), kind: .space)))
            read.observe(.messageReceived(Message(
                id: .init("message-\(index)"), conversationID: id, threadID: .init("thread"),
                sender: peer.id, text: "Fixture", createdAt: Date(timeIntervalSince1970: 1)
            )))
        }
        #expect(read.accepts(members: [peer.id]))
    }

    @Test func changedReturnedProfilesAndOwnMembershipStillFenceTheRead() {
        var read = PendingManagementRead(conversation: id, baseline: nil)
        read.observe(.membersResolved([peer]))
        #expect(!read.accepts(members: [peer.id]))
        #expect(read.accepts(members: []))
        read.observe(.membersChanged(conversationID: id, members: []))
        #expect(!read.accepts(members: []))
    }

    @Test func continuityLossStillFencesTheRead() {
        var read = PendingManagementRead(conversation: id, baseline: nil)
        read.observe(.gap(scope: .everything, reason: "fixture"))
        #expect(!read.accepts(members: []))
    }
}
