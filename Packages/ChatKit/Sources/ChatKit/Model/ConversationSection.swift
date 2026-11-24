import Foundation

public struct ConversationSection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let conversationIDs: Set<Conversation.ID>
    public let sort: SidebarSortOrder
    public let unreadOnly: Bool

    public init(
        id: String, name: String, conversationIDs: Set<Conversation.ID>,
        sort: SidebarSortOrder = .activity, unreadOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.conversationIDs = conversationIDs
        self.sort = sort
        self.unreadOnly = unreadOnly
    }

    public static func isValidID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
    }

    public static func isValidName(_ value: String) -> Bool {
        isValidID(value) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public extension Capabilities {
    var canReadConversationSections: Bool {
        extendedFlags.contains("conversationSections")
    }

    var canEditConversationSections: Bool {
        canReadConversationSections && extendedFlags.contains("editConversationSections")
    }

    var canManageConversationSections: Bool {
        canEditConversationSections && extendedFlags.contains("manageConversationSections")
    }

    var canMoveConversationSections: Bool {
        canReadConversationSections && extendedFlags.contains("moveConversationSections")
    }
}

public extension ChatBackend {
    /// Account sidebar sections in display order. An omitted collection is unavailable.
    func conversationSections() async throws -> [ConversationSection]? {
        throw ChatError.unsupported(capability: "conversationSections")
    }

    func updateConversationSection(_: ConversationSectionEdit) async throws {
        throw ChatError.unsupported(capability: "editConversationSections")
    }

    func createConversationSection(named _: String) async throws -> ConversationSection {
        throw ChatError.unsupported(capability: "manageConversationSections")
    }

    func deleteConversationSection(_: String) async throws {
        throw ChatError.unsupported(capability: "manageConversationSections")
    }

    func moveConversationToSection(_: ConversationSectionPlacement) async throws {
        throw ChatError.unsupported(capability: "moveConversationSections")
    }
}
