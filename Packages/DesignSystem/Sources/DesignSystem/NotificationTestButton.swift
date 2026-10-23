import ChatKit
import SwiftUI

/// What sending a test notification found: whether macOS took it, and what it
/// lets Kibble's notifications do. The host reads that from the system; this
/// only says it, so the person never presses a button that silently does nothing.
public enum NotificationTestOutcome: Equatable, Sendable {
    /// Banners and sounds are allowed.
    case sent
    case withoutSound
    case withoutBanner
    /// Delivered to Notification Center only, with neither banner nor sound.
    case quiet
    /// Kibble may not post notifications; nothing was sent.
    case notAllowed
    case failed

    public var message: String {
        switch self {
        case .sent:
            "Test notification sent. If you didn’t see or hear it, check whether a Focus is on."
        case .withoutSound:
            "Test notification sent without sound. Sounds are off for Kibble in System Settings."
        case .withoutBanner:
            "Test notification sent to Notification Center. Banners are off for Kibble in System Settings."
        case .quiet:
            "Test notification sent to Notification Center only. Banners and sounds are off for Kibble "
                + "in System Settings."
        case .notAllowed:
            "Notifications are off for Kibble. Turn them on in System Settings."
        case .failed:
            "Kibble couldn’t send the test notification. Try again."
        }
    }
}

/// Sends one notification through the ordinary delivery path with the
/// Defaults' sound, and keeps the result beside the button until the next try.
struct NotificationTestButton: View {
    let sound: NotificationSound
    let send: @MainActor (NotificationSound) async -> NotificationTestOutcome
    @Binding var outcome: NotificationTestOutcome?
    @State private var isSending = false

    var body: some View {
        Button("Send Test Notification") {
            isSending = true
            outcome = nil
            Task {
                outcome = await send(sound)
                isSending = false
            }
        }
        .disabled(isSending)
    }
}
