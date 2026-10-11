import ChatKit
import Foundation

/// Message search over the fixture world, for `--backend=fixture` and the
/// model's tests (search spec §2). Every filter, pages of five, and no clock:
/// "older than" is an instant the query carries.
public extension FakeBackend {
    static let searchPageSize = 5

    func searchMessages(_ query: MessageSearchQuery, after cursor: MessageSearchCursor?) async throws
        -> MessageSearchPage {
        try requireConnected()
        try require(capabilities.canSearchMessages, "canSearchMessages")
        var start = 0
        if let cursor {
            guard let offset = Int(cursor.rawValue), offset >= 0 else {
                throw ChatError.unknown("not a fixture search cursor: \(cursor)")
            }
            start = offset
        }
        let hits = Self.matches(query, in: world)
        let page = Array(hits.dropFirst(start).prefix(Self.searchPageSize))
        let end = start + page.count
        return MessageSearchPage(hits: page, next: end < hits.count ? MessageSearchCursor(String(end)) : nil)
    }

    /// Pure, so the filters are tested without a connection. Every word, in
    /// any order, ignoring case and accents. "Relevance" here is where the
    /// first word falls, then newer first: deterministic, not clever.
    static func matches(_ query: MessageSearchQuery, in world: FixtureWorld) -> [Message] {
        let words = folded(query.text).split(separator: " ").map(String.init)
        guard !words.isEmpty || query.hasFilters else { return [] }
        let found = world.messages.filter { message in
            !message.isDeleted
                && words.allSatisfy { folded(message.text).contains($0) }
                && matchesFilters(message, query, meID: world.me)
        }
        guard case .relevance = query.order, let first = words.first else {
            return found.sorted { $0.createdAt > $1.createdAt }
        }
        func position(_ message: Message) -> Int {
            let text = folded(message.text)
            return text.range(of: first).map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
        }
        return found.sorted { lhs, rhs in
            let (left, right) = (position(lhs), position(rhs))
            return left != right ? left < right : lhs.createdAt > rhs.createdAt
        }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every filter but the words, so `matches(_:in:)` stays readable.
    private static func matchesFilters(
        _ message: Message,
        _ query: MessageSearchQuery,
        meID: Member.ID
    ) -> Bool {
        if let from = query.from, message.sender != from {
            return false
        }
        if let conversation = query.conversation, message.conversationID != conversation {
            return false
        }
        if let olderThan = query.olderThan, message.createdAt >= olderThan {
            return false
        }
        if let newerThan = query.newerThan, message.createdAt < newerThan {
            return false
        }
        if query.hasFile, message.attachments.isEmpty {
            return false
        }
        if query.hasLink, message.links.isEmpty {
            return false
        }
        if query.mentionsMe, !message.mentions.contains(where: { $0.target == .user(meID) }) {
            return false
        }
        return true
    }
}
