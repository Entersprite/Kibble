import ChatKit

extension SyncEngine {
    func starredMessages(
        after cursor: String?, pages count: Int, visited: Set<String>
    ) async throws -> [StarredMessagesPage] {
        let generation = managementGeneration
        var pages: [StarredMessagesPage] = []
        var seen = visited
        var next = cursor
        for _ in 0 ..< count {
            if let next {
                seen.insert(next)
            }
            try Task.checkCancellation()
            let page = try await backend.starredMessages(after: next)
            try Task.checkCancellation()
            guard generation == managementGeneration else { throw CancellationError() }
            if let returned = page.nextCursor, seen.contains(returned) {
                throw ChatError.decoding("The starred messages page repeated a cursor.")
            }
            pages.append(page)
            next = page.nextCursor
            if next == nil {
                break
            }
        }
        return pages
    }

    func setMessageStarred(_ starred: Bool, at address: MessageAddress) async throws {
        let generation = managementGeneration
        try Task.checkCancellation()
        try await backend.setMessageStarred(starred, at: address)
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
    }
}
