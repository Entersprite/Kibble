public struct ConversationSectionPlacement: Codable, Hashable, Sendable {
    public let conversationID: Conversation.ID
    public let sectionID: String?

    /// Passing nil returns the conversation to its ordinary sidebar group.
    public init(conversationID: Conversation.ID, sectionID: String?) {
        self.conversationID = conversationID
        self.sectionID = sectionID
    }

    public var isValid: Bool {
        ConversationSection.isValidID(conversationID.rawValue)
            && (sectionID.map(ConversationSection.isValidID) ?? true)
    }

    public func applying(to sections: [ConversationSection]) -> [ConversationSection] {
        sections.map { section in
            var members = section.conversationIDs
            if section.id == sectionID {
                members.insert(conversationID)
            } else {
                members.remove(conversationID)
            }
            guard members != section.conversationIDs else { return section }
            return ConversationSection(
                id: section.id, name: section.name, conversationIDs: members,
                sort: section.sort, unreadOnly: section.unreadOnly
            )
        }
    }
}
