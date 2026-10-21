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

    /// The symbol beside the row menu's item. Checked to exist by
    /// `SidebarSymbolTests`: a wrong name compiles and draws nothing.
    var menuSymbol: String {
        switch self {
        case .markUnread: "envelope.badge"
        case .leave: "rectangle.portrait.and.arrow.right"
        case .hide: "eye.slash"
        case .block: "hand.raised"
        case .delete: "trash"
        case .unknown: "questionmark.circle"
        }
    }

    var needsConfirmation: Bool {
        self == .block || self == .leave || self == .delete
    }

    /// The alert's title names the conversation, as the details sheet's and
    /// the account confirmations do, so the question says what it acts on.
    func confirmationTitle(named title: String) -> String {
        switch self {
        case .leave: "Leave “\(title)”?"
        case .block: "Block “\(title)”?"
        case .delete: "Delete “\(title)”?"
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

    var confirmationTitle: String {
        action.confirmationTitle(named: title)
    }
}
