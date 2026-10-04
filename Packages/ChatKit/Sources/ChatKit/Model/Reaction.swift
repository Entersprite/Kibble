import Foundation

/// A reaction summary: one emoji, and how many people used it.
///
/// A summary rather than a list of reactors. **[Verify]** the internal protocol
/// does appear to carry per-user reaction detail, but nothing in this repo has
/// confirmed what it contains under user authentication, and the public Chat
/// API exposes only a count. Modelling reactor identity now would mean
/// inventing a field no backend can fill, so `includesMe` carries the one piece
/// of identity a client actually needs — whether to draw the button as
/// selected.
///
/// Coding is synthesised. Every field is a scalar, there are no timestamps and
/// no default-on-absence decisions to make, so a hand-written coder would only
/// add a place for a future field to be forgotten. `CodingKeys` is spelled out
/// so the wire names are visible in the file that owns them.
///
/// `customEmoji` is set for a workspace's custom emoji, and then `emoji` holds
/// its `displayText`, so a reader that does not know the field still has
/// something to show. Absent means unicode.
public struct Reaction: Codable, Hashable, Sendable {
    public var emoji: String
    public var count: Int
    public var includesMe: Bool
    public var customEmoji: CustomEmojiRef?

    public init(emoji: String, count: Int, includesMe: Bool = false, customEmoji: CustomEmojiRef? = nil) {
        self.emoji = emoji
        self.count = count
        self.includesMe = includesMe
        self.customEmoji = customEmoji
    }

    enum CodingKeys: String, CodingKey {
        case emoji
        case count
        case includesMe
        case customEmoji
    }
}

public extension Reaction {
    /// See `ReactionChoice.key`.
    var key: String {
        choice.key
    }

    var choice: ReactionChoice {
        customEmoji.map(ReactionChoice.init(customEmoji:)) ?? ReactionChoice(emoji: emoji)
    }
}

public extension [Reaction] {
    /// One person's reaction added or removed: the person using this client
    /// when `isLocalUser`, anyone else otherwise.
    ///
    /// Idempotent for the local user in both directions, because a toggle acts
    /// on state it may not have seen yet: adding a reaction that is already
    /// theirs, or removing one that is not, changes nothing. Removing the last
    /// count drops the entry; a new emoji is appended, so the server's order
    /// is kept for everything else.
    func applying(_ choice: ReactionChoice, add: Bool, isLocalUser: Bool = true) -> [Reaction] {
        var reactions = self
        let index = reactions.firstIndex { $0.key == choice.key }
        switch (add, index) {
        case let (true, existing?):
            guard !isLocalUser || !reactions[existing].includesMe else { return reactions }
            reactions[existing].count += 1
            reactions[existing].includesMe = reactions[existing].includesMe || isLocalUser
        case (true, nil):
            reactions.append(Reaction(
                emoji: choice.emoji, count: 1, includesMe: isLocalUser, customEmoji: choice.customEmoji
            ))
        case let (false, existing?):
            guard !isLocalUser || reactions[existing].includesMe else { return reactions }
            // Through a local: swiftlint's empty_count reads `…count <= 0` as
            // a collection emptiness check, and this is a tally.
            let remaining = reactions[existing].count - 1
            reactions[existing].count = remaining
            if isLocalUser {
                reactions[existing].includesMe = false
            }
            if remaining < 1 {
                reactions.remove(at: existing)
            }
        case (false, nil):
            break
        }
        return reactions
    }
}
