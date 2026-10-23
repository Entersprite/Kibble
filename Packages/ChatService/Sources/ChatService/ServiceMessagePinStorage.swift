import ChatKit

/// Confirmed display snapshots in the account's canonical projection.
public protocol ServiceMessagePinStorage: Sendable {
    func cachedMessagePins(in conversation: Conversation.ID) throws -> PinnedMessages?
}
