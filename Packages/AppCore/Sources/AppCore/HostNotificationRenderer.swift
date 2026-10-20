import ChatAPI
import ChatKit
import SyncEngine

@MainActor
public enum HostNotificationRenderer {
    /// `accountLabel` is the client's name for the account while several are
    /// connected, and `nil` with one: the service's own label is not shown.
    public static func render(_ post: HostNotificationPost, accountLabel: String?) -> MessageNotification {
        var notification = NotificationCoordinator.notification(
            for: post.message, in: post.conversation,
            directory: Dictionary(
                post.members.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            ),
            me: post.me, presentation: .init(
                isPassive: post.isPassive, playsSound: post.playsSound, showsPreview: post.showsPreview
            ), offersMarkRead: post.offersMarkRead
        )
        if let accountLabel {
            notification.subtitle = notification.subtitle.map { $0 + " · " + accountLabel } ?? accountLabel
        }
        return notification
    }
}
