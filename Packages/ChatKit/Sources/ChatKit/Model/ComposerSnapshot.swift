import Foundation

/// Local unsent composition, scoped by the account's replica. Not a send operation.
public struct ComposerSnapshot: Codable, Equatable, Sendable {
    public var conversation: Conversation.ID
    public var thread: MessageThread.ID?
    public var text: String
    public var mentions: [Mention]
    public var caret: Int
    public var quote: MessageQuote?

    public init(
        conversation: Conversation.ID, thread: MessageThread.ID? = nil,
        text: String, mentions: [Mention] = [], caret: Int = 0, quote: MessageQuote? = nil
    ) {
        self.conversation = conversation
        self.thread = thread
        self.text = text
        self.mentions = mentions
        self.caret = caret
        self.quote = quote
    }
}
