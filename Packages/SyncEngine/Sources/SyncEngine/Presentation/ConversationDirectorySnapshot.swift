import ChatKit

struct ConversationDirectorySnapshot {
    var query: String
    var scope: SpaceDirectoryScope
    var organization: SpaceDirectoryOrganization
    var people: [Member]
    var spaces: [ConversationDetails]
    var cursor: String?
    var error: String?
    var wasLoading: Bool
}

extension ConversationBrowser {
    func saveDirectory() {
        guard let page else { return }
        directorySnapshots[page] = ConversationDirectorySnapshot(
            query: query,
            scope: scope,
            organization: organization,
            people: people,
            spaces: spaces,
            cursor: nextCursor,
            error: error,
            wasLoading: isLoading
        )
    }
}
