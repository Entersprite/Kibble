import Foundation

public extension Capabilities {
    var canManageConversationEmail: Bool {
        extendedFlags.contains("conversationEmail")
    }

    var canManageConversationApps: Bool {
        extendedFlags.contains("conversationApps")
    }

    var canManageConversationWebhooks: Bool {
        extendedFlags.contains("conversationWebhooks")
    }
}
