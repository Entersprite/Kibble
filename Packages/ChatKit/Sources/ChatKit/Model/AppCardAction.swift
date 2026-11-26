import Foundation

/// A provider-issued action identifier. Clients never interpret its contents.
public struct AppCardAction: Codable, Hashable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct AppCardActionRequest: Codable, Hashable, Sendable {
    public var conversation: Conversation.ID
    public var thread: MessageThread.ID
    public var message: Message.ID
    public var action: AppCardAction

    public init(
        conversation: Conversation.ID,
        thread: MessageThread.ID,
        message: Message.ID,
        action: AppCardAction
    ) {
        self.conversation = conversation
        self.thread = thread
        self.message = message
        self.action = action
    }
}

/// Acceptance is distinct from completion of work in an external application.
public struct AppCardActionResult: Codable, Hashable, Sendable {
    public var card: AppCard?
    public var setupURL: URL?

    public init(card: AppCard? = nil, setupURL: URL? = nil) {
        self.card = card
        self.setupURL = setupURL
    }
}

public extension Capabilities {
    var canInvokeCardActions: Bool {
        extendedFlags.contains("cardActions")
    }
}

public extension ChatBackend {
    func invokeCardAction(_: AppCardActionRequest) async throws -> AppCardActionResult {
        throw ChatError.unsupported(capability: "cardActions")
    }
}
