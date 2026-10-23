import ChatKit
import Foundation

/// The sheet's words, apart from its layout.
enum ConversationDetailsText {
    static func kind(_ kind: Conversation.Kind) -> String {
        switch kind {
        case .space: "Space"
        case .groupDirectMessage: "Group Chat"
        case .appDirectMessage: "App"
        case .meetChat: "Meet Chat"
        default: "Conversation"
        }
    }

    static func subtitle(_ details: ConversationDetails) -> String {
        var parts = [kind(details.conversation.kind)]
        switch details.membership {
        case .joined:
            if let members = Display.memberCountLabel(of: details.conversation) {
                parts.append(members)
            }
        case .invited: parts.append("Invited")
        case .requested: parts.append("Request pending")
        default: parts.append("Not joined")
        }
        return parts.joined(separator: " · ")
    }

    static func joinTitle(_ mutation: ConversationMutation) -> String {
        switch mutation {
        case .requestJoin: "Ask to Join"
        case .acceptInvitation: "Accept Invitation"
        default: "Join Space"
        }
    }

    static func role(_ role: ConversationRole) -> String {
        switch role {
        case .owner: "Owner"
        case .manager: "Manager"
        case .member: "Member"
        default: "Unknown Role"
        }
    }

    @MainActor
    static func confirmationTitle(
        _ mutation: ConversationMutation,
        details: ConversationDetails,
        state: ChatSceneState
    ) -> String {
        let title = Display.title(of: details.conversation, directory: state.directory, me: state.me)
        switch mutation {
        case .leave: return "Leave “\(title)”?"
        case .deleteSpace: return "Delete “\(title)”?"
        case .declineInvitation: return "Decline the invitation to “\(title)”?"
        case let .removePerson(id):
            return "Remove \(Display.name(of: id, in: people(state))) from “\(title)”?"
        case let .rejectRequest(id):
            return "Reject \(Display.name(of: id, in: people(state)))’s request to join?"
        default: return "Change “\(title)”?"
        }
    }

    static func confirmationMessage(_ mutation: ConversationMutation) -> String {
        switch mutation {
        case .leave: "You’ll stop getting its messages. To come back, you’ll need to join or be added again."
        case .deleteSpace: "The space and all of its messages are deleted for everyone. This can’t be undone."
        case .declineInvitation: "The space won’t appear in your list."
        case .removePerson: "They’ll stop getting its messages."
        default: "They won’t be added."
        }
    }

    static func confirmationButton(_ mutation: ConversationMutation) -> String {
        switch mutation {
        case .leave: "Leave"
        case .deleteSpace: "Delete"
        case .declineInvitation: "Decline"
        case .removePerson: "Remove"
        default: "Reject"
        }
    }

    /// Participants' names as well as the directory's, for confirmations
    /// about people the directory may not know yet.
    @MainActor
    private static func people(_ state: ChatSceneState) -> [Member.ID: Member] {
        var people = state.directory
        for participant in state.browser.participants {
            people[participant.id] = participant.member
        }
        return people
    }
}
