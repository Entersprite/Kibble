import Foundation

/// Where a quote, a forward or a link points: a conversation, and possibly
/// one message in it with the thread it sits in. The identifiers are the
/// backend's own and stay opaque above it; an address grants nothing, and a
/// client opens one only in a conversation it already has.
public struct MessageAddress: Codable, Hashable, Sendable {
    public var conversation: Conversation.ID
    public var thread: MessageThread.ID?
    public var message: Message.ID?

    public init(conversation: Conversation.ID, thread: MessageThread.ID? = nil, message: Message.ID? = nil) {
        self.conversation = conversation
        self.thread = thread
        self.message = message
    }

    /// A quote's or a forward's source, when it names one: a snapshot whose
    /// source the backend could not address has empty identifiers.
    public init?(_ quote: MessageQuote) {
        guard !quote.conversation.rawValue.isEmpty, !quote.id.rawValue.isEmpty else { return nil }
        self.init(
            conversation: quote.conversation,
            thread: quote.thread.rawValue.isEmpty ? nil : quote.thread,
            message: quote.id
        )
    }

    private enum CodingKeys: String, CodingKey { case conversation, thread, message }
}
