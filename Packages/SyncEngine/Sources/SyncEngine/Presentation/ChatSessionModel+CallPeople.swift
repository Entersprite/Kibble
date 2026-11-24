import ChatKit
import Foundation

public extension ChatSessionModel {
    func searchCallPeople(_ query: String) async throws -> [Member] {
        try Task.checkCancellation()
        let members = try await engine.searchPeople(query)
        try Task.checkCancellation()
        return members.filter { $0.kind == .human && $0.id != me }
    }

    func openCallGuestChat(to address: String, while isCurrent: @MainActor () -> Bool) async throws {
        let selection = selected
        @MainActor func checkScope() throws {
            try Task.checkCancellation()
            guard isCurrent(), selected == selection else { throw CancellationError() }
        }
        try checkScope()
        guard capabilities.canOpenDirectConversations else {
            throw ChatError.unsupported(capability: "canOpenDirectConversations")
        }
        let people = try await searchCallPeople(address)
        try checkScope()
        let matches = Set(people.compactMap { person -> Member.ID? in
            guard !person.id.rawValue.isEmpty, person.email?.caseInsensitiveCompare(address) == .orderedSame
            else { return nil }
            return person.id
        })
        guard matches.count == 1, let member = matches.first else {
            throw ChatError.unknown("This person could not be found in Chat.")
        }
        if let existing = visibleDirectConversation(with: member) {
            openSearchConversation(existing.id)
            return
        }
        let conversation = await engine.openDirectConversation(with: member)
        try checkScope()
        guard let conversation
        else { throw ChatError.unknown("The direct conversation could not be opened.") }
        openSearchConversation(conversation.id)
    }

    internal func visibleDirectConversation(with member: Member.ID) -> Conversation? {
        conversations.first { $0.kind == .directMessage && $0.members.contains(member) }
    }
}
