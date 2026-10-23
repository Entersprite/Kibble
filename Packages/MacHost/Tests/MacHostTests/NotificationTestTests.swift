import ChatKit
import DesignSystem
import Foundation
import Testing
import UserNotifications
@testable import MacHost

/// The pure half of Settings' test notification. Posting needs a real
/// notification center, which a test runner does not have.
struct NotificationTestTests {
    @Test("What Notification Center allows decides the outcome", arguments: [
        (
            UNAuthorizationStatus.authorized,
            UNNotificationSetting.enabled,
            UNNotificationSetting.enabled,
            NotificationTestOutcome.sent
        ),
        (.authorized, .enabled, .disabled, .withoutSound),
        (.authorized, .disabled, .enabled, .withoutBanner),
        (.authorized, .disabled, .disabled, .quiet),
        (.provisional, .enabled, .enabled, .quiet),
        (.denied, .enabled, .enabled, .notAllowed),
        (.notDetermined, .enabled, .enabled, .notAllowed)
    ])
    func outcome(
        _ authorization: UNAuthorizationStatus,
        _ alert: UNNotificationSetting,
        _ sound: UNNotificationSetting,
        _ expected: NotificationTestOutcome
    ) {
        #expect(UserNotificationDelivery.testOutcome(
            authorization: authorization, alert: alert, sound: sound
        ) == expected)
    }

    /// The same cue a message would play, even where a message's own rule
    /// plays none: the test exists to be heard.
    @Test func theTestUsesTheChosenSound() {
        #expect(UserNotificationDelivery.testContent(sound: .kibble).sound
            == UNNotificationSound(named: UNNotificationSoundName("Kibble-Message-1.aiff")))
        #expect(UserNotificationDelivery.testContent(sound: .system).sound == .default)
    }

    /// Banner-capable, and carrying nothing a click or a withdrawal could read
    /// as a conversation or an account.
    @Test func theTestNamesNoConversationOrAccount() {
        let content = UserNotificationDelivery.testContent(sound: .kibble)
        #expect(content.interruptionLevel == .active)
        #expect(content.categoryIdentifier.isEmpty)
        #expect(content.userInfo.isEmpty)
        #expect(!content.title.isEmpty && !content.body.isEmpty)
        #expect(!content.title.contains("Google") && !content.body.contains("Google"))
        #expect(UserNotificationDelivery.testIdentifier.hasPrefix("kibble."))
        #expect(!UserNotificationDelivery.testIdentifier.hasPrefix("account."))
    }
}
