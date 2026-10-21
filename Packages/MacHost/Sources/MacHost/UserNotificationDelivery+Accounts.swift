import AppCore
import ChatAPI
import ChatKit
import Foundation
import UserNotifications

extension UserNotificationDelivery {
    static let accountScopeKey = "accountBinding"

    static func accountScope(in userInfo: [AnyHashable: Any]) -> AccountNotificationScope? {
        guard let data = userInfo[accountScopeKey] as? Data, data.count <= 16 * 1024 else { return nil }
        return try? ServiceCodec.decode(AccountNotificationScope.self, from: data)
    }

    static func scopedIdentifier(_ value: String, scope: AccountNotificationScope) -> String {
        // Encoding the tuple keeps opaque IDs unambiguous, even when they
        // contain punctuation used by our prefix or another account's IDs.
        let parts = [scope.service.rawValue, scope.account.rawValue, scope.revision.rawValue, value]
        return "account." + parts.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }

    static func scopedContent(_ notification: MessageNotification, scope: AccountNotificationScope) throws
        -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle ?? ""
        content.body = notification.body
        content.sound = messageSound(playsSound: notification.playsSound)
        content.interruptionLevel = notification.isPassive ? .passive : .active
        content.threadIdentifier = scopedIdentifier(notification.conversationID.rawValue, scope: scope)
        content.categoryIdentifier = category(for: notification)
        content.userInfo = userInfo(for: notification)
        content.userInfo[accountScopeKey] = try ServiceCodec.encode(scope)
        return content
    }

    public func post(_ notification: MessageNotification, scope: AccountNotificationScope) async {
        guard let content = try? Self.scopedContent(notification, scope: scope) else { return }
        let request = UNNotificationRequest(
            identifier: Self.scopedIdentifier(notification.id, scope: scope),
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    public func withdraw(
        in conversation: Conversation.ID,
        coveredBy position: Date,
        scope: AccountNotificationScope
    ) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().map {
            Delivered(
                identifier: $0.request.identifier,
                thread: $0.request.content.threadIdentifier,
                userInfo: $0.request.content.userInfo
            )
        }
        let identifiers = Self.covered(
            delivered,
            in: Self.scopedIdentifier(conversation.rawValue, scope: scope),
            upTo: Self.micros(position)
        )
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func withdrawAll(in scope: AccountNotificationScope) async {
        await removeMessages { Self.accountScope(in: $0) == scope }
    }

    public func retainNotifications(in scopes: Set<AccountNotificationScope>) async {
        await removeMessages { userInfo in
            guard userInfo[Self.accountScopeKey] != nil else { return false }
            guard let scope = Self.accountScope(in: userInfo) else { return true }
            return !scopes.contains(scope)
        }
    }

    func withdrawLegacyNotifications() async {
        await removeMessages { $0[Self.accountScopeKey] == nil }
    }

    private func removeMessages(matching predicate: ([AnyHashable: Any]) -> Bool) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let identifiers = delivered.filter { predicate($0.request.content.userInfo) }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
