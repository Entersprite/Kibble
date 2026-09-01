import ChatKit
import Foundation

/// One group of conversations in the sidebar.
public struct SidebarSection: Identifiable, Sendable, Hashable {
    /// Stable across rebuilds, so SwiftUI keeps expansion state and does not
    /// animate a section out and back in when its contents change.
    public let id: String
    public let title: String
    public let conversations: [Conversation]
}

/// How the sidebar is grouped and ordered.
///
/// Pure, and therefore actually tested. Grouping rules written inside a view
/// body get verified by looking at them, which is how a sidebar ends up sorting
/// by the epoch.
public enum SidebarSections {
    /// Sections in display order, omitting any that would be empty.
    public static func build(_ conversations: [Conversation]) -> [SidebarSection] {
        order.compactMap { kind in
            let matching = conversations
                .filter { key(for: $0.kind) == kind.id }
                .sorted(by: isOrderedBefore)
            guard !matching.isEmpty else { return nil }
            return SidebarSection(id: kind.id, title: kind.title, conversations: matching)
        }
    }

    /// Mirrors the prototype's order, with two additions the prototype had no
    /// need for: apps, and anything this build does not recognise.
    private static let order: [(id: String, title: String)] = [
        ("directMessage", "Direct messages"),
        ("groupDirectMessage", "Group chats"),
        ("space", "Spaces"),
        ("appDirectMessage", "Apps"),
        ("other", "Other")
    ]

    /// A conversation kind this build has never seen goes under "Other".
    ///
    /// Not dropped, and not guessed at. The fixture world ships a
    /// `.unknown("meetCall")` conversation exactly so this path is exercised;
    /// labelling it "Meet" would be the UI asserting something the protocol
    /// work has not established.
    private static func key(for kind: Conversation.Kind) -> String {
        switch kind {
        case .directMessage: "directMessage"
        case .groupDirectMessage: "groupDirectMessage"
        case .space: "space"
        case .appDirectMessage: "appDirectMessage"
        case .unknown: "other"
        }
    }

    /// Most recent first. `lastActivity == nil` means "never, or not known
    /// yet", so it sorts below everything rather than being read as the epoch;
    /// ties break on identifier so the order never wobbles between rebuilds.
    private static func isOrderedBefore(_ left: Conversation, _ right: Conversation) -> Bool {
        switch (left.lastActivity, right.lastActivity) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            leftDate > rightDate
        case (nil, .some):
            false
        case (.some, nil):
            true
        default:
            left.id.rawValue < right.id.rawValue
        }
    }
}
