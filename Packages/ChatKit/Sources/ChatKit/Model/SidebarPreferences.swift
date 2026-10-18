import Foundation

/// Personal navigation choices. These do not change a conversation's kind or notification rules.
public struct SidebarPreferences: Codable, Equatable, Sendable {
    public var sections: [SidebarSectionPreference]
    public var favoriteConversations: Set<Conversation.ID>
    public var favoriteMeetings: Set<MeetingSeries.ID>

    public init(
        sections: [SidebarSectionPreference] = [],
        favoriteConversations: Set<Conversation.ID> = [],
        favoriteMeetings: Set<MeetingSeries.ID> = []
    ) {
        self.sections = sections
        self.favoriteConversations = favoriteConversations
        self.favoriteMeetings = favoriteMeetings
    }

    private enum CodingKeys: String, CodingKey {
        case sections, favoriteConversations, favoriteMeetings
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sections = try values.decodeIfPresent([SidebarSectionPreference].self, forKey: .sections) ?? []
        favoriteConversations = try values.decodeIfPresent(
            Set<Conversation.ID>.self,
            forKey: .favoriteConversations
        ) ?? []
        favoriteMeetings = try values
            .decodeIfPresent(Set<MeetingSeries.ID>.self, forKey: .favoriteMeetings) ?? []
    }

    /// Favorites is always first, visible when populated, and unlimited.
    /// Only its sorting choices are configurable.
    public var favoritesSection: SidebarSectionPreference {
        var section = sections.first { $0.id == "favorites" } ?? .init(id: "favorites")
        section.isVisible = true
        section.maximumItems = Int.max
        return section
    }

    public var displaySections: [SidebarSectionPreference] {
        [favoritesSection] + orderedSections
    }

    public var orderedSections: [SidebarSectionPreference] {
        var seen: Set<String> = []
        return (sections + Self.defaults).filter {
            Self.identifiers.contains($0.id) && seen.insert($0.id).inserted
        }.map { section in
            var section = section
            if section.maximumItems < 1 {
                section.maximumItems = 10
            }
            return section
        }
    }

    public static let identifiers = [
        "directMessage",
        "groupDirectMessage",
        "space",
        "appDirectMessage",
        "meetChat"
    ]
    public static let defaults: [SidebarSectionPreference] = [
        .init(id: "directMessage"),
        .init(id: "groupDirectMessage"),
        .init(id: "space", sort: .name),
        .init(id: "appDirectMessage"),
        .init(id: "meetChat")
    ]

    public mutating func update(_ section: SidebarSectionPreference) {
        let favorites = section.id == "favorites" ? section : favoritesSection
        sections = [favorites] + orderedSections.map { $0.id == section.id ? section : $0 }
    }
}

public struct SidebarSectionPreference: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var isVisible: Bool
    public var maximumItems: Int
    public var sort: SidebarSortOrder
    public var isAscending: Bool?

    public var sortsAscending: Bool {
        isAscending ?? (sort == .name)
    }

    public init(
        id: String,
        isVisible: Bool = true,
        maximumItems: Int = 10,
        sort: SidebarSortOrder = .activity,
        isAscending: Bool? = nil
    ) {
        self.id = id
        self.isVisible = isVisible
        self.maximumItems = maximumItems
        self.sort = sort
        self.isAscending = isAscending
    }

    public var title: String {
        switch id {
        case "favorites": "Favorites"
        case "directMessage": "Direct Messages"
        case "groupDirectMessage": "Group Chats"
        case "space": "Spaces"
        case "appDirectMessage": "Apps"
        case "meetChat": "Meet Chats"
        default: "Conversations"
        }
    }
}

/// A local preference token; unknown stored values fall back to activity ordering.
public struct SidebarSortOrder: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let activity = Self(rawValue: "activity")
    public static let name = Self(rawValue: "name")
}
