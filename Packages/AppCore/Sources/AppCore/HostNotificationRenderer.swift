import ChatAPI
import ChatKit
import SyncEngine

@MainActor
public enum HostNotificationRenderer {
    public static func render(_ post: HostNotificationPost) -> MessageNotification {
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
        notification.subtitle = notification.subtitle.map { $0 + " · " + post.accountLabel } ?? post
            .accountLabel
        return notification
    }
}
