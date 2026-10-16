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
            let sorted = matching.sorted { left, right in
                if section.sort == .name {
                    let comparison = Display.title(of: left, directory: directory, me: me)
                        .localizedStandardCompare(Display.title(of: right, directory: directory, me: me))
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
                return left.id.rawValue < right.id.rawValue
            }
            return SidebarSection(
                id: section.id, title: section.title,
                conversations: limited ? Array(sorted.prefix(section.maximumItems)) : sorted
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
