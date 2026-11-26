import ChatKit
import Foundation
import Testing
import UserNotifications
@testable import MacHost

@MainActor
struct ScopedCallNotificationTests {
    @Test func identicalCallIDsFromDifferentAccountsHaveDifferentNativeAddresses() throws {
        let call = UUID(); let first = UUID(); let second = UUID()
        let firstAlert = IncomingCallAlert(id: call, title: "Person", delivery: .banner, scope: first)
        let secondAlert = IncomingCallAlert(id: call, title: "Person", delivery: .banner, scope: second)
        #expect(UserNotificationDelivery.callIdentifier(call, scope: first)
            != UserNotificationDelivery.callIdentifier(call, scope: second))
        let firstContent = UserNotificationDelivery.callContent(firstAlert)
        let secondContent = UserNotificationDelivery.callContent(secondAlert)
        let response = try #require(UserNotificationDelivery.callResponse(
            action: UserNotificationDelivery.declineCallActionID, userInfo: firstContent.userInfo
        ))
        #expect(response == .decline(call, scope: first))
        #expect(response.scope != second)
        #expect(UserNotificationDelivery.callResponse(
            action: UserNotificationDelivery.answerCallActionID, userInfo: secondContent.userInfo
        ) == .answer(call, scope: second))
    }

    @Test func malformedScopeNeverFallsBackToAnUnscopedAction() {
        let info: [AnyHashable: Any] = [
            UserNotificationDelivery.callKey: UUID().uuidString,
            UserNotificationDelivery.callScopeKey: "malformed"
        ]
        #expect(UserNotificationDelivery.callResponse(
            action: UserNotificationDelivery.answerCallActionID, userInfo: info
        ) == nil)
    }
}
