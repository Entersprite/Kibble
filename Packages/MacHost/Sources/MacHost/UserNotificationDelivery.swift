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
    /// The same notification with no "Mark as Read" button - for a
    /// conversation whose rule withholds read receipts, where
    /// `SyncEngine.submit(_:)` would refuse the mark (`offersMarkRead`). Raw
    /// value kept as the pre-rename `"messageNoActions"` so a banner
    /// delivered before this build still resolves to a registered category.
    static let withoutMarkReadCategoryID = "messageNoActions"
    static let markReadActionID = "markRead"
    static let muteActionID = "mute"
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

    /// Makes this the center's delegate and registers the notification
    /// categories. **Must run before the app finishes launching** - Apple's
    /// rule for receiving the response that launched the app - which is why
    /// `MacAppDelegate` calls it from `applicationWillFinishLaunching`.
    @MainActor
    public func install() {
        center.delegate = self
        center.setNotificationCategories(Self.categories())
    }

    /// Both categories, registered together: each `setNotificationCategories`
    /// call replaces the whole set. Neither action has `.foreground`: marking
    /// read or muting must not pull the app forward.
    static func categories() -> Set<UNNotificationCategory> {
        let markRead = UNNotificationAction(identifier: markReadActionID, title: "Mark as Read", options: [])
        let mute = UNNotificationAction(identifier: muteActionID, title: "Mute", options: [])
        return [
            UNNotificationCategory(
                identifier: categoryID, actions: [markRead, mute], intentIdentifiers: [], options: []
            ),
            UNNotificationCategory(
                identifier: withoutMarkReadCategoryID, actions: [mute], intentIdentifiers: [], options: []
            )
        ]
    }

    static func response(
        to actionIdentifier: String,
        in conversation: Conversation.ID
    ) -> NotificationResponse? {
        switch actionIdentifier {
        case markReadActionID: .markRead(conversation)
        case muteActionID: .mute(conversation)
        case UNNotificationDefaultActionIdentifier: .open(conversation)
        default: nil
        }
    }

    /// `.badge` as well as alerts and sounds: once an app registers with
    /// Notification Center, macOS gates `NSDockTile.badgeLabel` on its "Badge
    /// application icon" setting, and that setting only exists for an app
    /// that asked for `.badge` - see `DockBadge`.
    public func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
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
        content.categoryIdentifier = Self.category(for: notification)
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
        let delivered = await center.deliveredNotifications().map { notification in
            Delivered(
                identifier: notification.request.identifier,
                thread: notification.request.content.threadIdentifier,
                userInfo: notification.request.content.userInfo
            )
        }
        let covered = Self.covered(delivered, in: conversation.rawValue, before: Self.micros(position))
        guard !covered.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: covered)
    }

    /// What `withdraw` needs from a delivered notification, copied out of it
    /// so the filter runs without a notification center.
    struct Delivered: Sendable, Equatable {
        let identifier: String
        let thread: String
        /// `createdAtKey`'s value, or `nil` when it is missing or not an
        /// integer - it comes back from the center as an `NSNumber`.
        let createdAt: Int64?

        init(identifier: String, thread: String, userInfo: [AnyHashable: Any]) {
            self.identifier = identifier
            self.thread = thread
            createdAt = userInfo[UserNotificationDelivery.createdAtKey] as? Int64
        }
    }

    /// The identifiers a read position covers: same thread, and created
    /// strictly before `limit` - `findings.md` §36's boundary. One with no
    /// recorded time is left alone: nothing proves the position covers it.
    static func covered(_ delivered: [Delivered], in thread: String, before limit: Int64) -> [String] {
        delivered.filter { item in
            guard item.thread == thread, let created = item.createdAt else { return false }
            return created < limit
        }
        .map(\.identifier)
    }

    public func withdrawAll() async {
        center.removeAllDeliveredNotifications()
    }

    /// Which registered category a notification is posted under - the one
    /// with "Mark as Read" only where that button can act.
    ///
    /// **Fixed when posted** - a rule changed afterwards leaves the old
    /// buttons, accepted by the owner (2026-09-25): every click is checked
    /// again when it happens.
    static func category(for notification: MessageNotification) -> String {
        notification.offersMarkRead ? categoryID : withoutMarkReadCategoryID
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
        if let response = Self.response(to: response.actionIdentifier, in: conversation) {
            continuation.yield(response)
        }
    }
}
