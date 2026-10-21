import ChatKit
import Foundation
import Testing
@testable import ChatRules

struct CallNotificationPolicyTests {
    @Test func callActivityNeverUsesTheOrdinaryMessageAlertEvenWithAMention() {
        for status in [MessageCallStatus.started, .missed, .ended, .unknown("future")] {
            var message = message()
            message.callStatus = status
            #expect(decision(message) == .suppress(.callActivity))
            message.text = ""
            #expect(decision(message) == .suppress(.callActivity))
        }
    }

    @Test func ordinaryTextThatLooksLikeACallStillNotifies() {
        #expect(decision(message()) == .post(.init(
            isPassive: false, playsSound: true, showsPreview: true
        )))
    }

    private func message() -> Message {
        Message(
            id: .init("message"),
            conversationID: .init("dm"),
            threadID: .init("thread"),
            sender: .init("peer"),
            text: "Call started",
            createdAt: .distantPast
        )
    }

    private func decision(_ message: Message) -> NotificationPolicy.Decision {
        NotificationPolicy.decide(.init(
            message: message, rule: .builtIn, me: .init("self"), viewing: nil,
            alreadyAnnounced: false, paused: false, mentionsMe: true
        ))
    }
}
