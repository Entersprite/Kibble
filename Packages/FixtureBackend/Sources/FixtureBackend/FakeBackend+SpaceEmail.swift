import ChatKit
import Foundation

public extension FakeBackend {
    func conversationEmail(_ id: Conversation.ID) async throws -> ConversationEmail {
        try require(capabilities.canManageConversationEmail, "conversationEmail")
        let details = try await conversationDetails(id)
        guard details.conversation.kind == .space, details.membership == .joined else {
            throw ChatError.unsupported(capability: "conversationEmail")
        }
        var value = managedEmails[id] ?? ConversationEmail()
        value.canGenerate = value.address == nil && details.allowedActions.contains("generateEmail")
        value.canChangeDelivery = value.address != nil && details.allowedActions.contains("setEmailDelivery")
        value.canDelete = value.address != nil && details.allowedActions.contains("deleteEmail")
        return value
    }
}

extension FakeBackend {
    func changeManagedEmail(_ mutation: ConversationMutation, in id: Conversation.ID) throws {
        try require(capabilities.canManageConversationEmail, "conversationEmail")
        var value = managedEmails[id] ?? ConversationEmail()
        switch mutation {
        case .generateEmail:
            guard value.address == nil else { throw ChatError.unsupported(capability: "generateEmail") }
            value.address = nextIdentifier("fixture-space") + "@example.invalid"
            value.deliveryEnabled = true
        case let .setEmailDelivery(enabled):
            guard value.address != nil else { throw ChatError.unsupported(capability: "setEmailDelivery") }
            value.deliveryEnabled = enabled
        case .deleteEmail:
            guard value.address != nil else { throw ChatError.unsupported(capability: "deleteEmail") }
            value = ConversationEmail()
        default: throw ChatError.unsupported(capability: "conversationEmail")
        }
        managedEmails[id] = value
    }
}
