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
