public struct ConversationSectionEdit: Codable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let sort: SidebarSortOrder?
    public let unreadOnly: Bool?

    public init(id: String, name: String? = nil, sort: SidebarSortOrder? = nil, unreadOnly: Bool? = nil) {
        self.id = id
        self.name = name
        self.sort = sort
        self.unreadOnly = unreadOnly
    }

    public var isValid: Bool {
        guard ConversationSection.isValidID(id),
              name != nil || sort != nil || unreadOnly != nil else { return false }
        if let sort, sort != .activity, sort != .name {
            return false
        }
        guard let name else { return true }
        return ConversationSection.isValidName(name)
    }

    public func applying(to section: ConversationSection) -> ConversationSection? {
        guard id == section.id else { return nil }
        return ConversationSection(
            id: id, name: name ?? section.name, conversationIDs: section.conversationIDs,
            sort: sort ?? section.sort, unreadOnly: unreadOnly ?? section.unreadOnly
        )
    }
}
