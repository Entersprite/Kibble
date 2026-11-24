import ChatKit
import Foundation

/// What the draft answers about the mention being typed, apart for
/// `ComposerDraft.swift`'s length.
public extension ComposerDraft {
    /// How far back from the caret an `@` may be and still open the list.
    internal static let maxQueryLength = 40

    /// The token Backspace removes whole, if the caret sits at its end.
    func token(endingAt offset: Int) -> Token? {
        tokens.first { $0.end == offset }
    }

    /// The `@query` the caret is in, per spec §2: an `@` at the start or after
    /// whitespace, on the caret's line, not inside a token, with no leading
    /// space in the query and no more than `maxQueryLength` units back.
    var activeQuery: Query? {
        let units = text as NSString
        guard caret <= units.length,
              !tokens.contains(where: { $0.location < caret && caret <= $0.end }) else { return nil }
        var index = caret
        while index > 0, caret - index < Self.maxQueryLength {
            index -= 1
            let unit = units.character(at: index)
            if unit == 0x0A || unit == 0x0D {
                return nil
            }
            guard unit == 0x40 else { continue }
            if index > 0, !Self.isWhitespace(units.character(at: index - 1)) {
                return nil
            }
            if tokens.contains(where: { $0.location == index }) {
                return nil
            }
            let query = units.substring(with: NSRange(location: index + 1, length: caret - index - 1))
            if query.first?.isWhitespace == true {
                return nil
            }
            return Query(location: index, text: query)
        }
        return nil
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        UnicodeScalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
    }
}

extension ComposerDraft {
    static func tokens(for message: ComposedMessage) -> [Token] {
        let units = message.text as NSString
        return message.mentions.compactMap { mention in
            guard mention.start >= 0, mention.length > 1, mention.start + mention.length <= units.length,
                  units.character(at: mention.start) == 0x40 else { return nil }
            let name = units.substring(with: NSRange(location: mention.start + 1, length: mention.length - 1))
            return Token(location: mention.start, length: mention.length, target: mention.target, name: name)
        }
    }

    /// Whether `token`'s span still reads `@name` in `text`.
    static func reads(_ token: Token, in text: String) -> Bool {
        let units = text as NSString
        guard token.location >= 0, token.end <= units.length else { return false }
        return units.substring(with: NSRange(location: token.location, length: token.length)) == "@" + token
            .name
    }
}
