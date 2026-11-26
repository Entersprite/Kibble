import ChatKit
import Foundation
import Testing
@testable import ChatRules

struct MessagePinPolicyTests {
    @Test func structuredActivityInvalidatesPinsWithoutAnOrdinaryMessageAlert() {
        var message = Message(
            id: .init("activity"), conversationID: .init("room"), threadID: .init("thread"),
            sender: .init("peer"), text: "", createdAt: .distantPast, activity: .pinnedMessage
        )
        #expect(SyncReducer.reduce(.messageReceived(message)).writes
            .contains(.invalidateMessagePins(.init("room"))))
        for activity in [MessageActivity.pinnedMessage, .pinnedResource, .unknown("future")] {
            message.activity = activity
            #expect(NotificationPolicy.decide(.init(
                message: message, rule: .builtIn, me: .init("self"), viewing: nil,
                alreadyAnnounced: false, paused: false, mentionsMe: true
            )) == .suppress(.conversationActivity))
        }
        message.activity = nil
        #expect(!SyncReducer.reduce(.messageReceived(message)).writes
            .contains(.invalidateMessagePins(.init("room"))))
    }
}
