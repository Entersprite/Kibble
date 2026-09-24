import AppCore
import ChatKit
import Foundation
import UserNotifications

/// The one conformance to `NotificationDelivering` that reaches the real
/// notification center - and so the one file in the repo that cannot run under
/// a test runner (`UNUserNotificationCenter.current()` needs a real bundle).
/// Kept to plumbing for that reason: every decision is made above it.
///
/// `@unchecked Sendable` because every stored property is a `let` of a type
/// that is safe to share - the stream and its continuation are `Sendable`, and
/// the center is only ever reached through `current()`.
public final class UserNotificationDelivery: NSObject, NotificationDelivering, @unchecked Sendable {
    public let responses: AsyncStream<NotificationResponse>
    private let continuation: AsyncStream<NotificationResponse>.Continuation

    static let categoryID = "message"
    static let markReadActionID = "markRead"
    static let conversationKey = "conversationID"
    /// Microseconds since 1970, as an integer. Not the `Date`'s `Double`
    /// seconds: at today's epoch a `Double` has barely a microsecond of
    /// precision left, and `withdraw` compares against a position that is one
    /// microsecond past the newest message (`findings.md` §36) - a rounding
    /// error there is the difference between a banner withdrawn and one left up.
    static let createdAtKey = "createdAtMicros"

    override public init() {
        // Buffered so a click that launches the app is still there when the
        // coordinator starts listening a moment later.
        (responses, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        super.init()
    }

    private var center: UNUserNotificationCenter {
        .current()
    }

    /// Makes this the center's delegate and registers the "Mark as Read"
    /// button. **Must run before the app finishes launching** - Apple's rule
    /// for receiving the response that launched the app - which is why
    /// `MacAppDelegate` calls it from `applicationWillFinishLaunching`.
    @MainActor
    public func install() {
        center.delegate = self
        // No `.foreground` option: marking read must not pull the app forward.
        let markRead = UNNotificationAction(
            identifier: Self.markReadActionID, title: "Mark as Read", options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID, actions: [markRead], intentIdentifiers: [], options: []
            )
        ])
    }

    public func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func post(_ notification: MessageNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle {
            content.subtitle = subtitle
        }
        content.body = notification.body
        content.sound = notification.playsSound ? .default : nil
        content.interruptionLevel = notification.isPassive ? .passive : .active
        // Groups a conversation's notifications together, and is what
        // `withdraw` filters on.
        content.threadIdentifier = notification.conversationID.rawValue
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [
            Self.conversationKey: notification.conversationID.rawValue,
            Self.createdAtKey: Self.micros(notification.createdAt)
        ]
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// Asks the center what it is showing rather than keeping a list, so a
    /// banner posted before a relaunch is withdrawn too. A notification with no
    /// recorded time is left alone: nothing proves the position covers it.
    public func withdraw(in conversation: Conversation.ID, coveredBy position: Date) async {
        let limit = Self.micros(position)
        let covered = await center.deliveredNotifications()
            .filter { delivered in
                let content = delivered.request.content
                guard content.threadIdentifier == conversation.rawValue,
                      let created = content.userInfo[Self.createdAtKey] as? Int64
                else { return false }
                return created < limit
            }
            .map(\.request.identifier)
        guard !covered.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: covered)
    }

    public func withdrawAll() async {
        center.removeAllDeliveredNotifications()
    }

    static func micros(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }
}

extension UserNotificationDelivery: UNUserNotificationCenterDelegate {
    /// Shows banners even while the app is frontmost. The coordinator has
    /// already suppressed anything on screen; what reaches here is a
    /// conversation the user is *not* looking at, and the system's default for
    /// a frontmost app would silently drop it.
    public func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Passive means no banner, frontmost or not.
        notification.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list, .sound]
    }

    public func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[Self.conversationKey] as? String else { return }
        let conversation = Conversation.ID(raw)
        switch response.actionIdentifier {
        case Self.markReadActionID:
            continuation.yield(.markRead(conversation))
        case UNNotificationDefaultActionIdentifier:
            continuation.yield(.open(conversation))
        default:
            break
        }
    }
}
