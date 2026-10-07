import ChatKit
import SwiftUI

/// A message's mentions as highlighted ranges of its text (mentions spec §5).
///
/// A span's `start` and `length` count UTF-16 code units - measured on the
/// live account, `findings.md` §41.1 - and are checked, never trusted: a span
/// outside the text, off a `Character` boundary, or not beginning with `@` is
/// dropped. A wrong reading of the unit therefore shows no highlight, never a
/// wrong one. §41.1 also found the literal `@Name` in the text, so the `@`
/// check passes on real traffic rather than silently dropping every span.
public enum MentionHighlight {
    public static func ranges(
        in text: String, mentions: [Mention], me: Member.ID?
    ) -> [(range: Range<String.Index>, isMe: Bool)] {
        let units = text.utf16
        return mentions.compactMap { mention in
            guard mention.start >= 0, mention.length > 0,
                  mention.length <= units.count - mention.start,
                  let lower = String.Index(
                      units.index(units.startIndex, offsetBy: mention.start), within: text
                  ),
                  let upper = String.Index(
                      units.index(units.startIndex, offsetBy: mention.start + mention.length), within: text
                  ),
                  text[lower] == "@"
            else { return nil }
            return (lower ..< upper, isMe(mention.target, me))
        }
    }

    /// Ruling 6: in your own (accent-filled) bubble a mention is only
    /// semibold, since accent on accent would be unreadable. In anyone
    /// else's, a mention of you or `@all` gets an accent background at 25%,
    /// and a mention of someone else an accent foreground. `[Verify]` in the
    /// running app - a test can read the attributes, not see them.
    ///
    /// The ranges are `String.Index` values from `text`, converted with
    /// `Range(_:in:)` into an `AttributedString` built from that same `text`.
    /// That relies on the two sharing one character content, which they do
    /// here by construction. A conversion that fails anyway is dropped - no
    /// highlight, never a wrong one.
    public static func attributed(
        _ text: String, mentions: [Mention], links: [MessageLink] = [], me: Member.ID?, inOwnBubble: Bool
    ) -> AttributedString {
        var attributed = AttributedString(text)
        for (range, isMe) in ranges(in: text, mentions: mentions, me: me) {
            guard let span = Range(range, in: attributed) else { continue }
            attributed[span].font = .body.weight(.semibold)
            guard !inOwnBubble else { continue }
            if isMe {
                attributed[span].backgroundColor = Color.accentColor.opacity(0.25)
            } else {
                attributed[span].foregroundColor = .accentColor
            }
        }
        // Links where `MessageLinks` puts them (links spec §7.2), never over a
        // mention.
        let mentionRanges = ranges(in: text, mentions: mentions, me: me).map { NSRange($0.range, in: text) }
        for span in MessageLinks.spans(in: text, links: links, avoiding: mentionRanges) {
            guard let range = Range(span.range, in: text),
                  let target = Range(range, in: attributed) else { continue }
            attributed[target].link = span.url
        }
        return attributed
    }

    private static func isMe(_ target: Mention.Target, _ me: Member.ID?) -> Bool {
        switch target {
        case let .user(id): id == me
        case .all: true
        case .unknown: false
        }
    }
}
