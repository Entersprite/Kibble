import ChatKit
import ChatRules
import Foundation
import GRDB

/// Recent reactions and the custom emoji this account has seen (reactions
/// slice 2): what the picker's Recent and Custom sections and the quick row
/// are built from.
package extension ChatStore {
    /// One more use of `choice`, at `date`. A token arriving with a later use
    /// replaces none with one, never one with none.
    public func recordReactionUse(_ choice: ReactionChoice, at date: Date) throws {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO emojiRecent (key, emoji, customEmojiID, shortcode, imageToken, usedAt, uses)
                VALUES (?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(key) DO UPDATE SET
                    emoji = excluded.emoji,
                    shortcode = excluded.shortcode,
                    imageToken = COALESCE(excluded.imageToken, emojiRecent.imageToken),
                    usedAt = excluded.usedAt,
                    uses = emojiRecent.uses + 1
                """,
                arguments: [
                    choice.key, choice.emoji, choice.customEmoji?.id, choice.customEmoji?.shortcode,
                    choice.customEmoji?.imageToken, date.timeIntervalSince1970
                ]
            )
        }
    }

    /// Newest first.
    func recentReactions(limit: Int) throws -> [ReactionChoice] {
        try database.read { db in try Self.fetchRecentReactions(limit: limit, db) }
    }

    /// For `ChatSessionModel.recentReactionChoices`: the views read recents
    /// while they render, so they get an observed value, never a store read
    /// per bubble per render (slice 2 review, Important 1).
    func observeRecentReactions(limit: Int) -> AsyncValueObservation<[ReactionChoice]> {
        ValueObservation
            .tracking { db in try Self.fetchRecentReactions(limit: limit, db) }
            .snapshotValues(in: database)
    }

    private static func fetchRecentReactions(limit: Int, _ db: Database) throws -> [ReactionChoice] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT emoji, customEmojiID, shortcode, imageToken
            FROM emojiRecent ORDER BY usedAt DESC LIMIT ?
            """,
            arguments: [limit]
        ).map { row in
            if let id: String = row["customEmojiID"], let shortcode: String = row["shortcode"] {
                return ReactionChoice(customEmoji: CustomEmojiRef(
                    id: id, shortcode: shortcode, imageToken: row["imageToken"]
                ))
            }
            return ReactionChoice(emoji: row["emoji"])
        }
    }

    /// Every distinct custom emoji in this account's stored reactions, in the
    /// order first met, preferring a reference that carries a token. The one
    /// read of reactions across messages, filtered in SQL to rows that can
    /// hold a custom emoji: off the main thread, once a session
    /// (`ChatSessionModel.customEmoji`), never while a view renders.
    func storedCustomEmoji() async throws -> [CustomEmojiRef] {
        let (rows, recents) = try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT reactions, content FROM message
                WHERE reactions LIKE '%customEmoji%' OR content LIKE '%customEmoji%'
                """
            )
            .map { (reactions: $0["reactions"] as String, content: $0["content"] as String?) }
            let recents = try Row.fetchAll(db, sql: """
            SELECT customEmojiID, shortcode, imageToken FROM emojiRecent
            WHERE customEmojiID IS NOT NULL AND shortcode IS NOT NULL
            ORDER BY usedAt DESC
            """).map { row in
                CustomEmojiRef(
                    id: row["customEmojiID"],
                    shortcode: row["shortcode"],
                    imageToken: row["imageToken"]
                )
            }
            return (rows, recents)
        }
        var seen = SeenCustomEmoji()
        for row in rows {
            if let reactions = try? Wire.value(
                [Reaction].self,
                from: row.reactions
            ) {
                seen.insert(contentsOf: reactions.compactMap(\.customEmoji))
            }
            if let json = row.content, let content = try? Wire.value(
                MessageContent.self,
                from: json
            ) {
                seen.insert(contentsOf: content.customEmoji.map(\.emoji))
                seen.insert(contentsOf: content.forwarded?.customEmoji.map(\.emoji) ?? [])
            }
        }
        seen.insert(contentsOf: recents)
        return seen.emoji
    }
}

/// Distinct custom emoji in the order first met. A reference that carries an
/// image token replaces one without: history and the live push do not always
/// both carry it (`findings.md` §54.3).
package struct SeenCustomEmoji: Equatable, Sendable {
    package private(set) var emoji: [CustomEmojiRef] = []
    private var indexByID: [String: Int] = [:]

    package init() {}

    /// Whether anything was added or replaced.
    @discardableResult
    package mutating func insert(contentsOf candidates: some Sequence<CustomEmojiRef>) -> Bool {
        var changed = false
        for candidate in candidates {
            if let index = indexByID[candidate.id] {
                if emoji[index].imageToken == nil, candidate.imageToken != nil {
                    emoji[index] = candidate
                    changed = true
                }
            } else {
                indexByID[candidate.id] = emoji.count
                emoji.append(candidate)
                changed = true
            }
        }
        return changed
    }
}
