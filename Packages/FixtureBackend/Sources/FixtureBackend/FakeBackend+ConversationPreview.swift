import ChatKit
import Foundation

public extension FakeBackend {
    /// A few messages from the directory's people for any conversation the
    /// fixture account has not joined, timed from the world's start so the
    /// same world previews the same way every run. Nothing is stored.
    func conversationPreview(_ id: Conversation.ID) async throws -> ConversationPreview {
        try requireConnected()
        try require(capabilities.canPreviewConversations, "canPreviewConversations")
        guard world.conversation(id) == nil, managedDetails[id] != nil else {
            throw ChatError.unknown("This conversation has no preview.")
        }
        let people = Array((directory + world.members).filter { $0.id != world.me && $0.kind == .human }
            .prefix(2))
        guard !people.isEmpty else { return ConversationPreview() }
        let lines = [
            "Welcome! This is where we share what we are working on.",
            "The notes from this week are pinned at the top.",
            "Thanks, I will take a look this afternoon."
        ]
        let messages = lines.enumerated().map { index, text in
            Message(
                id: Message.ID("\(id.rawValue)|preview-\(index)"),
                conversationID: id,
                threadID: MessageThread.ID("\(id.rawValue)|preview-topic-\(index)"),
                sender: people[index % people.count].id,
                text: text,
                createdAt: world.startedAt.addingTimeInterval(Double(index - lines.count) * 3600)
            )
        }
        return ConversationPreview(messages: messages, members: people)
    }
}
