import ChatKit
import DesignSystem
import Foundation
import UserNotifications

/// Settings' test notification: a real post through the same center, delegate
/// and sound installation a message uses. Notification Center stays in charge:
/// it is asked what Kibble may do first, and Focus filters the post as it
/// filters every other one.
extension UserNotificationDelivery {
    /// One test at a time is shown; a newer test replaces the older banner.
    static let testIdentifier = "kibble.notification-test"

    public func sendTest(sound: NotificationSound) async -> NotificationTestOutcome {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            // The same request the first message makes, so a first test asks.
            await requestAuthorization()
            settings = await center.notificationSettings()
        }
        let outcome = Self.testOutcome(
            authorization: settings.authorizationStatus,
            alert: settings.alertSetting,
            sound: settings.soundSetting
        )
        guard outcome != .notAllowed else { return outcome }
        center.removeDeliveredNotifications(withIdentifiers: [Self.testIdentifier])
        // Custom sounds are published by `messageSound`; Kibble's own cue is
        // published at launch, and again here in case it was removed since.
        if sound == .kibble {
            try? MessageNotificationSound.install()
        }
        let request = UNNotificationRequest(
            identifier: Self.testIdentifier, content: Self.testContent(sound: sound), trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            return .failed
        }
        return outcome
    }

    static func testOutcome(
        authorization: UNAuthorizationStatus,
        alert: UNNotificationSetting,
        sound: UNNotificationSetting
    ) -> NotificationTestOutcome {
        switch authorization {
        case .authorized:
            switch (alert == .disabled, sound == .disabled) {
            case (false, false): .sent
            case (false, true): .withoutSound
            case (true, false): .withoutBanner
            case (true, true): .quiet
            }
        // Provisional delivery goes to Notification Center without a banner or sound.
        case .provisional: .quiet
        default: .notAllowed
        }
    }

    /// No category and no user info: a click opens Kibble and addresses no
    /// conversation or account.
    static func testContent(sound: NotificationSound) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Test Notification"
        content.body = "Notifications from Kibble look and sound like this."
        content.sound = messageSound(playsSound: true, sound: sound)
        content.interruptionLevel = .active
        content.threadIdentifier = testIdentifier
        return content
    }
}
