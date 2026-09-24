import AppCore
import ChatKit
import Foundation
import Testing
@testable import MacHost

/// The pure half of the one file that reaches the real notification center.
/// Everything here runs without `UNUserNotificationCenter`, which crashes
/// under a test runner.
struct UserNotificationDeliveryTests {
    private func notification(offersMarkRead: Bool) -> MessageNotification {
        MessageNotification(
            id: "m:1", conversationID: Conversation.ID("space/1"), title: "Design", subtitle: nil,
            body: "hello", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            offersMarkRead: offersMarkRead
        )
    }

    /// "Mark as Read" lives on the category, so the category is the button.
    @Test func onlyANotificationThatOffersMarkAsReadGetsTheCategoryWithTheButton() {
        #expect(UserNotificationDelivery.category(for: notification(offersMarkRead: true))
            == UserNotificationDelivery.categoryID)
        #expect(UserNotificationDelivery.category(for: notification(offersMarkRead: false))
            == UserNotificationDelivery.noActionsCategoryID)
        #expect(UserNotificationDelivery.categoryID != UserNotificationDelivery.noActionsCategoryID)
    }
}
