import ChatKit
import Foundation

/// Sidebar presentation is independent of provider kinds and notification-rule sections.
public enum SidebarProjection {
    public static func build(
        _ conversations: [Conversation], preferences: SidebarPreferences,
        directory: [Member.ID: Member] = [:], me: Member.ID? = nil,
        limited: Bool = true, customSections: [ConversationSection] = []
    ) -> [SidebarSection] {
        let meetings = MeetingSeries.build(conversations)
        let assigned = Set(customSections.flatMap(\.conversationIDs))
        let unassigned = conversations.filter { !assigned.contains($0.id) }
        let unassignedMeetings = assigned.isEmpty ? meetings : MeetingSeries.build(unassigned)
        let builtIn = preferences.displaySections.filter(\.isVisible)
            .compactMap { section -> SidebarSection? in
                let isFavorites = section.id == "favorites"
                let matching = (isFavorites ? conversations : unassigned).filter {
                    isFavorites ? preferences.favoriteConversations
                        .contains($0.id) : sectionID(for: $0.kind) == section.id
                }
                let groups = isFavorites ? meetings.filter { preferences.favoriteMeetings.contains($0.id) } :
                    section.id == "meetChat" ? unassignedMeetings : []
                let grouped = Set(groups.flatMap { $0.occurrences.map(\.id) })
                let items = matching.filter { !grouped.contains($0.id) }.map(SidebarItem.conversation)
                    + groups.map(SidebarItem.meeting)
                let sorted = sortedItems(items, by: section, directory: directory, me: me)
                guard !isFavorites || !sorted.isEmpty else { return nil }
                let visible = limited && !isFavorites ? Array(sorted.prefix(section.maximumItems)) : sorted
                return SidebarSection(
                    id: section.id, title: section.title,
                    conversations: visible.compactMap(\.conversation),
                    items: visible
                )
            }
        guard !customSections.isEmpty else { return builtIn }
        let byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let custom = customSections.map { section in
            let matching = section.conversationIDs.compactMap { byID[$0] }.filter {
                !section.unreadOnly || $0.hasUnread || $0.markedUnreadAt != nil || $0.hasUnreadThread
            }
            let id = "custom:" + section.id
            let order = SidebarSectionPreference(id: id, sort: section.sort)
            let sorted = sortedItems(
                matching.map(SidebarItem.conversation),
                by: order,
                directory: directory,
                me: me
            )
            return SidebarSection(
                id: id, title: section.name, conversations: sorted.compactMap(\.conversation),
                items: sorted, customSectionID: section.id
            )
        }
        return Array(builtIn.prefix { $0.id == "favorites" }) + custom + builtIn
            .filter { $0.id != "favorites" }
    }

    private static func sortedItems(
        _ items: [SidebarItem], by section: SidebarSectionPreference,
        directory: [Member.ID: Member], me: Member.ID?
    ) -> [SidebarItem] {
        items.sorted { left, right in
            if section.sort != .name, left.lastActivity != right.lastActivity {
                switch (left.lastActivity, right.lastActivity) {
                case let (left?, right?): return section.sortsAscending ? left < right : left > right
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            let comparison = left.title(directory: directory, me: me)
                .localizedStandardCompare(right.title(directory: directory, me: me))
            if comparison == .orderedSame {
                return left.stableOrder < right.stableOrder
            }
            return section.sort == .name && !section.sortsAscending ? comparison == .orderedDescending :
                comparison == .orderedAscending
        }
    }

    public static func sectionID(for kind: Conversation.Kind) -> String {
        switch kind {
        case .groupDirectMessage: "groupDirectMessage"
        case .space: "space"
        case .appDirectMessage: "appDirectMessage"
        case .meetChat: "meetChat"
        default: "directMessage"
        }
    }
}
