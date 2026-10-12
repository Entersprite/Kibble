import Foundation

public extension Capabilities {
    func supports(_ action: ConversationAction) -> Bool {
        switch action {
        case .markUnread: canMarkUnread
        case .hide: canHideConversations
        case .block: canBlockConversations
        case .leave: canLeaveConversations
        case .delete: canDeleteConversations
        case .unknown: false
        }
    }
}
