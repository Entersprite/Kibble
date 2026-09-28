import AppCore
import ChatKit
import Foundation
import Testing
import UserNotifications
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
            == UserNotificationDelivery.withoutMarkReadCategoryID)
        #expect(UserNotificationDelivery.categoryID != UserNotificationDelivery.withoutMarkReadCategoryID)
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
            [delivered("m:1", createdAt: createdAt)], in: thread, upTo: createdAt + 1
        )
        #expect(covered == ["m:1"])
    }

    /// A position equal to the message's own time covers it: that is what
    /// Google's own clients write for a read, and a `GROUP_VIEWED` from the
    /// phone passes it through unchanged (`findings.md` §42.2). Compared
    /// strictly, a read on the phone at exactly the head left the newest
    /// banner up on the Mac. A newer notification is still left up.
    @Test func aNotificationAtThePositionIsCoveredAndOneAfterItIsLeftAlone() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:at", createdAt: createdAt), delivered("m:after", createdAt: createdAt + 1)],
            in: thread, upTo: createdAt
        )
        #expect(covered == ["m:at"])
    }

    @Test func anotherConversationsNotificationIsLeftAlone() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:1", thread: "space/2", createdAt: createdAt)], in: thread, upTo: createdAt + 1
        )
        #expect(covered.isEmpty)
    }

    /// Nothing proves a position covers a notification with no recorded time.
    @Test func aNotificationWithNoUsableTimeIsLeftAlone() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:none", createdAt: nil), delivered("m:text", createdAt: "1790000000000000")],
            in: thread, upTo: createdAt + 1
        )
        #expect(covered.isEmpty)
    }

    /// The center hands `userInfo` back as property-list values, so the time
    /// arrives as an `NSNumber`, not the `Int64` that was posted.
    @Test func aTimeThatCameBackAsANumberIsRead() {
        let covered = UserNotificationDelivery.covered(
            [delivered("m:1", createdAt: NSNumber(value: createdAt))], in: thread, upTo: createdAt + 1
        )
        #expect(covered == ["m:1"])
    }

    /// At today's epoch a `Double` of seconds has well under a microsecond of
    /// precision to spare, so the conversion must round, not truncate: a
    /// position has to land on the microsecond it names, whether that is a
    /// message's own time or one past it. These three are values where the
    /// `Date` lands a hair short of the integer, so truncating reads the
    /// position one microsecond early - and a position equal to a message
    /// then leaves that message's banner up.
    @Test func microsecondsSurviveTheRoundTripThroughADate() {
        for micros: Int64 in [1_790_000_000_000_002, 1_790_000_000_000_007, 1_790_000_000_000_012] {
            let date = Date(timeIntervalSince1970: Double(micros) / 1_000_000)
            #expect(UserNotificationDelivery.micros(date) == micros)
            #expect(UserNotificationDelivery.micros(date.addingTimeInterval(0.000_001)) == micros + 1)
        }
    }

    // MARK: - Categories and responses

    /// Every banner carries Mute; only one whose conversation publishes
    /// receipts carries Mark as Read. One set, registered in one call,
    /// because each `setNotificationCategories` replaces the last.
    @Test func everyCategoryOffersMuteAndOnlyOneOffersMarkAsRead() {
        let categories = UserNotificationDelivery.categories()
        #expect(Set(categories.map(\.identifier))
            == [UserNotificationDelivery.categoryID, UserNotificationDelivery.withoutMarkReadCategoryID])
        for category in categories {
            let actions = category.actions.map(\.identifier)
            #expect(actions.contains(UserNotificationDelivery.muteActionID))
            #expect(actions.contains(UserNotificationDelivery.markReadActionID)
                == (category.identifier == UserNotificationDelivery.categoryID))
        }
    }

    @Test func eachButtonAndTheBannerItselfBecomeTheirResponse() {
        let dm = Conversation.ID("dm/1")
        #expect(UserNotificationDelivery
            .response(to: UserNotificationDelivery.muteActionID, in: dm) == .mute(dm))
        #expect(UserNotificationDelivery.response(to: UserNotificationDelivery.markReadActionID, in: dm)
            == .markRead(dm))
        #expect(UserNotificationDelivery
            .response(to: UNNotificationDefaultActionIdentifier, in: dm) == .open(dm))
        #expect(UserNotificationDelivery.response(to: UNNotificationDismissActionIdentifier, in: dm) == nil)
    }
}
