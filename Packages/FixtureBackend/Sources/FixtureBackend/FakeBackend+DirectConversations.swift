import ChatKit
import Foundation

public extension FakeBackend {
    func openDirectConversation(with member: Member.ID) async throws -> Conversation {
        try requireConnected()
        try require(capabilities.canOpenDirectConversations, "canOpenDirectConversations")
        guard !blockedDirectMembers.contains(member)
        else { throw ChatError.unknown("This person is blocked.") }
        guard member != world.me else { throw ChatError.unknown("Choose another person.") }
        if let conversation = world.conversations.first(where: {
            $0.kind == .directMessage && $0.members.contains(member)
        }) {
            hiddenConversations.remove(conversation.id)
            return conversation
        }
        var id: Conversation.ID
        repeat {
            nextDirectConversationNumber += 1
            id = Conversation.ID("fixture-dm-\(nextDirectConversationNumber)")
        } while world.conversations.contains {
            $0.id == id
        }
        let conversation = Conversation(
            id: id, kind: .directMessage,
            members: [world.me, member]
        )
        world.conversations.append(conversation)
        return conversation
    }
}
