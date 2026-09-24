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

    // MARK: - Which notifications a read position withdraws

    private let thread = "space/1"
    private let createdAt: Int64 = 1_790_000_000_000_001

    private func delivered(
        _ identifier: String, thread: String? = nil, createdAt: Any?
    ) -> UserNotificationDelivery.Delivered {
        var userInfo: [AnyHashable: Any] = [UserNotificationDelivery.conversationKey: thread ?? self.thread]
        userInfo[UserNotificationDelivery.createdAtKey] = createdAt
        return UserNotificationDelivery.Delivered(
            identifier: identifier,
            thread: thread ?? self.thread,
            userInfo: userInfo
        )
    }

    @Test func aPositionPastANotificationInItsThreadCoversIt() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:1", createdAt: createdAt)], in: thread, before: createdAt + 1
        )
        #expect(covered == ["m:1"])
    }

    /// Strictly before: a position equal to the message's own time does not
    /// cover it (`findings.md` §36), and a newer notification is left up.
    @Test func aNotificationAtOrAfterThePositionIsLeftAlone() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:at", createdAt: createdAt), delivered("m:after", createdAt: createdAt + 1)],
            in: thread, before: createdAt
        )
        #expect(covered.isEmpty)
    }

    @Test func anotherConversationsNotificationIsLeftAlone() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:1", thread: "space/2", createdAt: createdAt)], in: thread, before: createdAt + 1
        )
        #expect(covered.isEmpty)
    }

    /// Nothing proves a position covers a notification with no recorded time.
    @Test func aNotificationWithNoUsableTimeIsLeftAlone() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:none", createdAt: nil), delivered("m:text", createdAt: "1790000000000000")],
            in: thread, before: createdAt + 1
        )
        #expect(covered.isEmpty)
    }

    /// The center hands `userInfo` back as property-list values, so the time
    /// arrives as an `NSNumber`, not the `Int64` that was posted.
    @Test func aTimeThatCameBackAsANumberIsRead() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:1", createdAt: NSNumber(value: createdAt))], in: thread, before: createdAt + 1
        )
        #expect(covered == ["m:1"])
    }

    /// At today's epoch a `Double` of seconds has well under a microsecond of
    /// precision to spare, so the conversion must round, not truncate: a
    /// position one microsecond past a message has to stay one microsecond
    /// past it. These three are values where adding the microsecond in `Date`
    /// space lands a hair short of the next integer, so truncating reads the
    /// position as the message's own time and withdraws nothing.
    @Test func microsecondsSurviveTheRoundTripThroughADate() {
        for micros: Int64 in [1_790_000_000_000_002, 1_790_000_000_000_007, 1_790_000_000_000_012] {
            let date = Date(timeIntervalSince1970: Double(micros) / 1_000_000)
            #expect(UserNotificationDelivery.micros(date) == micros)
            #expect(UserNotificationDelivery.micros(date.addingTimeInterval(0.000_001)) == micros + 1)
        }
    }
}
