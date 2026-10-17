import Foundation
import UserNotifications

extension UserNotificationDelivery {
    static let callCategoryID = "incomingAudioCall"
    static let answerCallActionID = "answerAudioCall"
    static let declineCallActionID = "declineAudioCall"
    static let callKey = "localCallID"

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
        switch action {
        case UNNotificationDefaultActionIdentifier: return .show(id)
        case answerCallActionID: return .answer(id)
        case declineCallActionID: return .decline(id)
        default: return nil
        }
    }

    static func callIdentifier(_ id: UUID) -> String {
        "call.\(id.uuidString)"
    }

    static func callContent(_ alert: IncomingCallAlert) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = "Incoming audio call"
        content.categoryIdentifier = callCategoryID
        content.userInfo = [callKey: alert.id.uuidString]
        content.interruptionLevel = alert.delivery == .notificationCenter ? .passive : .active
        content.sound = alert.delivery == .bannerAndSound ? .default : nil
        return content
    }

    func postCall(_ alert: IncomingCallAlert) async {
        let request = UNNotificationRequest(
            identifier: Self.callIdentifier(alert.id), content: Self.callContent(alert), trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func withdrawCall(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        let identifiers = [Self.callIdentifier(id)]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
