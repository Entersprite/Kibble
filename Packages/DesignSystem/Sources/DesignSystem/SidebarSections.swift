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
        plan(for: conversations).compactMap { entry in
            let matching = conversations
                .filter { key(for: $0.kind) == entry.id }
                .sorted(by: isOrderedBefore)
            guard !matching.isEmpty else { return nil }
            return SidebarSection(id: entry.id, title: entry.title, conversations: matching)
        }
    }

    /// The named sections, then one per unrecognised kind actually present,
    /// then "Other".
    ///
    /// Unknown kinds used to share a single "Other" bucket, which was the
    /// right call while an unrecognised kind was a rarity. On the real account
    /// it is **187 of 220 conversations** - one heading saying nothing at all
    /// about the largest group in the sidebar. So each distinct unrecognised
    /// kind now gets its own section, **titled by its raw wire token**.
    ///
    /// That is the same discipline the old comment insisted on, carried one
    /// step further: a kind this build cannot name is not guessed at, and now
    /// it is not lumped in with every other unnameable kind either. The title
    /// is deliberately the token and not prose - naming it "Meet" would be the
    /// UI asserting what the protocol work has not established.
    ///
    /// "Other" is kept as the last entry for a `.unknown("")` - an empty token
    /// would otherwise produce a section with no heading at all.
    private static func plan(for conversations: [Conversation]) -> [(id: String, title: String)] {
        let unrecognised = Set(
            conversations.compactMap { conversation -> String? in
                guard case let .unknown(raw) = conversation.kind, !raw.isEmpty else { return nil }
                return raw
            }
        )
        .sorted()
        .map { (id: unknownKey($0), title: $0) }
        return named + unrecognised + [(id: "other", title: "Other")]
    }

    /// Mirrors the prototype's order, plus apps, which the prototype had no
    /// need for, and Meet chats. The mapping from kind to section now lives in
    /// `ChatKit.SectionKey`.
    ///
    /// **Meet chats go last on purpose.** On the real account they are 187 of
    /// 220 conversations, so any section placed after them is a long scroll
    /// away; Direct messages, Group chats, Spaces and Apps are the small,
    /// frequently-wanted ones and stay reachable at the top.
    private static let named: [(id: String, title: String)] =
        [SectionKey.directMessages, .groupChats, .spaces, .apps, .meetChats]
            .map { (id: sidebarID(for: $0), title: Display.title(of: $0)) }

    /// One section key per distinct unrecognised token. Prefixed so a token
    /// that happens to read `"space"` cannot collide with a named section.
    private static func unknownKey(_ raw: String) -> String {
        "unknown:\(raw)"
    }

    /// A conversation kind this build has never seen gets a section of its
    /// own, headed by its raw token. The mapping from kind to rule now lives in
    /// `ChatKit.SectionKey`.
    ///
    /// Not dropped, and not guessed at. The fixture world ships a
    /// `.unknown("meetCall")` conversation exactly so this path is exercised;
    /// labelling it "Meet" would be the UI asserting something the protocol
    /// work has not established - which is why the heading is the token
    /// itself. See `plan(for:)` for why these no longer share one bucket.
    private static func key(for kind: Conversation.Kind) -> String {
        sidebarID(for: SectionKey(kind: kind))
    }

    /// The section's stable sidebar id - unchanged from before `SectionKey`
    /// existed, because the collapse state and the tests key on it.
    private static func sidebarID(for section: SectionKey) -> String {
        switch section {
        case .directMessages: "directMessage"
        case .groupChats: "groupDirectMessage"
        case .spaces: "space"
        case .apps: "appDirectMessage"
        case .meetChats: "meetChat"
        case .other: "other"
        case let .unknown(raw): unknownKey(raw)
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
