import ChatKit
import Foundation

/// Ephemeral current interest, never a durable/retried operation. A hint can be
/// lost across a disconnect; clients re-establish their current interests.
public struct SendHint: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "sendHint"
    public static let requiresAccount = true
    public let command: ChatCommand

    public init(command: ChatCommand) {
        self.command = command
    }

    public static func accepts(_ command: ChatCommand) -> Bool {
        switch command {
        case .setTyping, .watchPresence, .watchConversationActivity, .loadMembers, .reportActivity: true
        default: false
        }
    }
}
