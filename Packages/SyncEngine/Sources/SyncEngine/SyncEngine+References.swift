import ChatKit
import ChatPersistence
import Foundation

public extension SyncEngine {
    func referencedMessagePreview(_ address: MessageAddress) async throws
        -> (quote: MessageQuote, author: Member?)? {
        guard let id = address.message,
              let message = try await referencedMessage(id, thread: address.thread, in: address.conversation)
        else { return nil }
        try Task.checkCancellation()
        let author = try store.members(identifiedBy: [message.sender]).first
        return (MessageQuote(message: message), author)
    }

    /// The message a quote, a forward or a link points at: the stored copy,
    /// or else the one its thread's listing brings, for a backend with
    /// threads. `nil` when neither holds it in that conversation.
    ///
    /// The listing is the thread panel's own request, so what it stores is a
    /// complete, confirmed message rather than the quote's partial copy.
    func referencedMessage(
        _ id: Message.ID, thread: MessageThread.ID?, in conversation: Conversation.ID
    ) async throws -> Message? {
        try Task.checkCancellation()
        guard try store.conversation(conversation) != nil else { return nil }
        if let stored = try store.message(id), stored.conversationID == conversation,
           thread == nil || stored.threadID == thread {
            return stored
        }
        guard let thread, !thread.rawValue.isEmpty, capabilities.supportsThreads else { return nil }
        try Task.checkCancellation()
        try await loadThread(thread, in: conversation)
        try Task.checkCancellation()
        guard try store.conversation(conversation) != nil else { return nil }
        return try store.message(id).flatMap {
            $0.conversationID == conversation && $0.threadID == thread ? $0 : nil
        }
    }
}
