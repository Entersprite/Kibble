import ChatKit
import Foundation

extension ConversationAction {
    var menuTitle: String {
        switch self {
        case .markUnread: "Mark as Unread"
        case .leave: "Leave…"
        case .hide: "Hide Conversation"
        case .block: "Block…"
        case .delete: "Delete Conversation…"
        case .unknown: "Unavailable"
        }
    }

    var needsConfirmation: Bool {
        self == .block || self == .leave || self == .delete
    }

    var confirmationTitle: String {
        switch self {
        case .leave: "Leave conversation?"
        case .block: "Block conversation?"
        case .delete: "Delete conversation?"
        default: menuTitle
        }
    }

    var confirmationMessage: String {
        switch self {
        case .leave: "You will leave this conversation and stop receiving its messages."
        case .block: "This conversation will be blocked and removed from your list."
        case .delete: "Your conversation history will be deleted for your account. "
            + "Other participants keep their history."
        default: ""
        }
    }

    var confirmationButton: String {
        switch self {
        case .leave: "Leave"
        case .block: "Block"
        case .delete: "Delete"
        default: menuTitle
        }
    }
}

struct PendingConversationAction: Identifiable {
    let conversation: Conversation.ID
    let action: ConversationAction
    let title: String
    let perform: (ConversationAction, Conversation.ID) -> Void
    var id: String {
        conversation.rawValue + action.wire
    }
}
