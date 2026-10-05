import ChatKit
import Foundation
import GRDB

/// Recent reactions and the custom emoji this account has seen (reactions
/// slice 2): what the picker's Recent and Custom sections and the quick row
/// are built from.
extension ChatStore {
    /// One more use of `choice`, at `date`. A token arriving with a later use
    /// replaces none with one, never one with none.
    func recordReactionUse(_ choice: ReactionChoice, at date: Date) throws {
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
        try database.read { db in
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
    }

    /// Every distinct custom emoji in this account's stored reactions, in the
    /// order first met, preferring a reference that carries a token. The one
    /// read of reactions across messages: run when the picker opens, not per
    /// render, and filtered in SQL to rows that can hold a custom emoji.
    func storedCustomEmoji() throws -> [CustomEmojiRef] {
        let rows = try database.read { db in
            try String.fetchAll(db, sql: "SELECT reactions FROM message WHERE reactions LIKE '%customEmoji%'")
        }
        var byID: [String: CustomEmojiRef] = [:]
        var order: [String] = []
        for json in rows {
            guard let reactions = try? Wire.value([Reaction].self, from: json) else { continue }
            for emoji in reactions.compactMap(\.customEmoji) {
                if let known = byID[emoji.id] {
                    if known.imageToken == nil, emoji.imageToken != nil {
                        byID[emoji.id] = emoji
                    }
                } else {
                    byID[emoji.id] = emoji
                    order.append(emoji.id)
                }
            }
        }
        return order.compactMap { byID[$0] }
    }
}
