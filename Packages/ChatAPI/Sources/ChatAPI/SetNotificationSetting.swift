import ChatKit
import Foundation

public struct SetNotificationSetting: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "setNotificationSetting"
    public static let requiresAccount = true
    public let level: NotificationLevel
    public let conversationID: Conversation.ID

    public init(level: NotificationLevel, conversationID: Conversation.ID) {
        self.level = level
        self.conversationID = conversationID
    }
}
