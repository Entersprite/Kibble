import ChatKit
import Foundation

/// Sidebar presentation is independent of provider kinds and notification-rule sections.
public enum SidebarProjection {
    public static func build(
        _ conversations: [Conversation], preferences: SidebarPreferences,
        directory: [Member.ID: Member] = [:], me: Member.ID? = nil,
        limited: Bool = true
    ) -> [SidebarSection] {
        preferences.orderedSections.filter(\.isVisible).map { section in
            let matching = conversations.filter { sectionID(for: $0.kind) == section.id }
            let groups = section.id == "meetChat" ? MeetingSeries.build(matching) : []
            let grouped = Set(groups.flatMap { $0.occurrences.map(\.id) })
            let items = matching.filter { !grouped.contains($0.id) }.map(SidebarItem.conversation)
                + groups.map(SidebarItem.meeting)
            let sorted = items.sorted { left, right in
                if section.sort == .name {
                    let comparison = left.title(directory: directory, me: me)
                        .localizedStandardCompare(right.title(directory: directory, me: me))
                    if comparison != .orderedSame {
                        return section.sortsAscending ? comparison == .orderedAscending :
                            comparison == .orderedDescending
                    }
                } else if left.lastActivity != right.lastActivity {
                    switch (left.lastActivity, right.lastActivity) {
                    case let (left?, right?): return section.sortsAscending ? left < right : left > right
                    case (.some, nil): return true
                    case (nil, .some): return false
                    default: break
                    }
                }
                let titleOrder = left.title(directory: directory, me: me)
                    .localizedStandardCompare(right.title(directory: directory, me: me))
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return left.stableOrder < right.stableOrder
            }
            let visible = limited ? Array(sorted.prefix(section.maximumItems)) : sorted
            return SidebarSection(
                id: section.id, title: section.title,
                conversations: visible.compactMap {
                    if case let .conversation(value) = $0 {
                        return value
                    }
                    return nil
                },
                items: visible
            )
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
