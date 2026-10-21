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
