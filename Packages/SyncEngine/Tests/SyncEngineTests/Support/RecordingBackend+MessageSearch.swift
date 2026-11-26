import ChatKit
@testable import ChatPersistence

extension RecordingBackend {
    func holdDirectOpens(_ held: Bool) {
        holdingDirectOpens = held
    }

    func openDirectConversation(with member: Member.ID) async throws -> Conversation {
        if holdingDirectOpens {
            try await abortableDirectOpens.wait()
        }
        return try await inner.openDirectConversation(with: member)
    }

    func searchMessages(_ query: MessageSearchQuery, after cursor: MessageSearchCursor?) async throws
        -> MessageSearchPage {
        messageSearches.append(RecordedSearch(query: query, cursor: cursor))
        if holdingMessageSearches {
            try await abortableMessageSearches.wait()
        }
        if failingMessageSearches {
            throw ChatError.server(status: 500, message: "the search failed")
        }
        if let scripted = scriptedSearchPages {
            let index = cursor.flatMap { Int($0.rawValue) } ?? 0
            return scripted.indices.contains(index) ? scripted[index] : MessageSearchPage()
        }
        return try await inner.searchMessages(query, after: cursor)
    }
}
