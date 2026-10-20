import Foundation
import UserNotifications

extension UserNotificationDelivery {
    static let callCategoryID = "incomingAudioCall"
    static let answerCallActionID = "answerAudioCall"
    static let declineCallActionID = "declineAudioCall"
    static let callKey = "localCallID"
    static let callScopeKey = "localCallScope"

    static var callCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: callCategoryID,
            actions: [
                UNNotificationAction(identifier: answerCallActionID, title: "Answer", options: [.foreground]),
                UNNotificationAction(identifier: declineCallActionID, title: "Decline", options: [])
            ], intentIdentifiers: [], options: []
        )
    }

    static func callResponse(action: String, userInfo: [AnyHashable: Any]) -> IncomingCallResponse? {
        guard let raw = userInfo[callKey] as? String, let id = UUID(uuidString: raw) else { return nil }
        let scope = (userInfo[callScopeKey] as? String).flatMap(UUID.init(uuidString:))
        guard userInfo[callScopeKey] == nil || scope != nil else { return nil }
        switch action {
        case UNNotificationDefaultActionIdentifier: return .show(id, scope: scope)
        case answerCallActionID: return .answer(id, scope: scope)
        case declineCallActionID: return .decline(id, scope: scope)
        default: return nil
        }
    }

    static func callIdentifier(_ id: UUID, scope: UUID? = nil) -> String {
        if let scope {
            return "call.\(scope.uuidString).\(id.uuidString)"
        }
        return "call.\(id.uuidString)"
    }

    static func callContent(_ alert: IncomingCallAlert) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = "Incoming audio call"
        content.categoryIdentifier = callCategoryID
        content.userInfo = [callKey: alert.id.uuidString]
        if let scope = alert.scope {
            content.userInfo[callScopeKey] = scope.uuidString
        }
        content.interruptionLevel = alert.delivery == .notificationCenter ? .passive : .active
        content.sound = alert.delivery == .bannerAndSound ? .default : nil
        return content
    }

    func postCall(_ alert: IncomingCallAlert) async {
        let request = UNNotificationRequest(
            identifier: Self.callIdentifier(alert.id, scope: alert.scope), content: Self.callContent(alert),
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func withdrawCall(_ id: UUID, scope: UUID? = nil) {
        let center = UNUserNotificationCenter.current()
        let identifiers = [Self.callIdentifier(id, scope: scope)]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
