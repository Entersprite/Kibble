import ChatKit
import Foundation

/// The composer's draft: its text, the mention tokens in it, and the caret.
/// The decisions worth testing live here, and the views only route into it.
///
/// A value type because this package's rule is that views take values and hand
/// back callbacks: a `@State String` inside `Composer` is not reachable from a
/// test. `ConnectionBanner.offersReconnect(for:)` is the shape this follows.
///
/// **Offsets are UTF-16 code units**, the unit `NSTextView` edits in and the
/// unit Google's mention spans count (`findings.md` §41.1), so a token's range
/// is a `Mention`'s span with no conversion.
///
/// It remembers what it last adopted, and that memory is the point. The host
/// clears its own copy of a failed draft once the composer reports adopting
/// it, but a redraw can still arrive carrying the same value, and re-adopting
/// would overwrite whatever the person has typed since.
public struct ComposerDraft: Equatable, Sendable {
    /// A picked mention: `@` plus `name`, at `location`.
    public struct Token: Equatable, Sendable {
        public var location: Int
        public var length: Int
        public var target: Mention.Target
        public var name: String

        public var end: Int {
            location + length
        }
    }

    /// The `@` being typed, and what follows it up to the caret.
    public struct Query: Equatable, Sendable {
        public var location: Int
        public var text: String
    }

    public private(set) var text = ""
    public private(set) var tokens: [Token] = []
    public private(set) var caret = 0
    private var adopted: ComposedMessage?

    /// The message being edited, when the field holds one (edit spec §5).
    public struct Editing: Equatable, Sendable {
        public let messageID: Message.ID
        /// What the field held before the edit began, given back when it ends.
        let setAside: ComposedMessage
    }

    public private(set) var editing: Editing?

    /// How far back from the caret an `@` may be and still open the list.
    static let maxQueryLength = 40

    public init() {}

    /// The whole text replaced at once: `TextField`'s binding, or anything
    /// the text view did that the edit routing did not see. Tokens survive
    /// only where the new text still reads `@name` at their offsets.
    public mutating func edit(_ text: String) {
        self.text = text
        tokens = tokens.filter { Self.reads($0, in: text) }
        caret = (text as NSString).length
    }

    public mutating func moveCaret(to offset: Int) {
        caret = min(max(0, offset), (text as NSString).length)
    }

    /// One edit, as `NSTextView` reports it. Tokens wholly before it stay,
    /// tokens wholly after it move, and a token the edit touches becomes plain
    /// text, so a mention is never sent whose text no longer names the person.
    public mutating func replace(location: Int, length: Int, with string: String) {
        let inserted = (string as NSString).length
        text = (text as NSString).replacingCharacters(
            in: NSRange(location: location, length: length),
            with: string
        )
        let end = location + length
        tokens = tokens.compactMap { token in
            if token.end <= location {
                return token
            }
            if token.location >= end {
                var moved = token
                moved.location += inserted - length
                return moved
            }
            return nil
        }
        caret = location + inserted
    }

    /// The token Backspace removes whole, if the caret sits at its end.
    public func token(endingAt offset: Int) -> Token? {
        tokens.first { $0.end == offset }
    }

    /// The `@query` the caret is in, per spec §2: an `@` at the start or after
    /// whitespace, on the caret's line, not inside a token, with no leading
    /// space in the query and no more than `maxQueryLength` units back.
    public var activeQuery: Query? {
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

    /// Replaces the active query with `@name ` and records the token.
    public mutating func pick(_ target: Mention.Target, name: String) {
        guard let query = activeQuery else { return }
        let mention = "@" + name
        replace(location: query.location, length: caret - query.location, with: mention + " ")
        tokens.append(Token(
            location: query.location,
            length: (mention as NSString).length,
            target: target,
            name: name
        ))
        tokens.sort { $0.location < $1.location }
    }

    /// What Send sends: the text trimmed of surrounding whitespace, and the
    /// tokens' spans shifted by what the trim removed in front.
    public func composed() -> ComposedMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ComposedMessage(text: "") }
        // `trimmed` starts at the first non-whitespace unit, so its first
        // occurrence is where the trim began.
        let start = (text as NSString).range(of: trimmed).location
        let end = start + (trimmed as NSString).length
        let mentions = tokens
            .filter { $0.location >= start && $0.end <= end && Self.reads($0, in: text) }
            .map { Mention(target: $0.target, start: $0.location - start, length: $0.length) }
        return ComposedMessage(text: trimmed, mentions: mentions)
    }

    /// Puts the field aside and loads `message`, tokens and all, with the
    /// caret at the end. Beginning again while editing keeps the first
    /// set-aside draft: the previous edit's text is not the person's draft.
    public mutating func beginEditing(_ messageID: Message.ID, with message: ComposedMessage) {
        let setAside = editing?.setAside ?? ComposedMessage(text: text, mentions: untrimmedMentions())
        text = message.text
        tokens = Self.tokens(for: message)
        caret = (text as NSString).length
        editing = Editing(messageID: messageID, setAside: setAside)
    }

    /// Ends the edit, saved or cancelled: hands back what the field held,
    /// and puts the set-aside draft back. `nil` when nothing was being edited.
    public mutating func endEditing() -> (messageID: Message.ID, message: ComposedMessage)? {
        guard let editing else { return nil }
        let edited = composed()
        self.editing = nil
        text = editing.setAside.text
        tokens = Self.tokens(for: editing.setAside)
        caret = (text as NSString).length
        return (editing.messageID, edited)
    }

    /// The tokens as mentions at their own offsets, untrimmed, so a set-aside
    /// draft comes back exactly as it was typed.
    private func untrimmedMentions() -> [Mention] {
        tokens.filter { Self.reads($0, in: text) }
            .map { Mention(target: $0.target, start: $0.location, length: $0.length) }
    }

    public mutating func clear() {
        text = ""
        tokens = []
        caret = 0
    }

    /// Adopts `restoring` if it is new, and says whether it did.
    ///
    /// A `nil` forgets what was adopted, so the same text failing a second
    /// time is offered again rather than silently dropped.
    ///
    /// **Never over what the person has typed since.** A failed upload can
    /// hand its caption back minutes after Send, by which time the field
    /// may hold the next message; the caption then goes first and the newer
    /// text after it, its tokens shifted, and nothing is lost.
    public mutating func adopt(_ restoring: ComposedMessage?) -> Bool {
        guard let restoring, !restoring.text.isEmpty else {
            adopted = nil
            return false
        }
        guard restoring != adopted else { return false }
        if let current = editing {
            // Never merged into the message being edited: it goes with the
            // set-aside draft, and is there when the edit ends.
            editing = Editing(
                messageID: current.messageID,
                setAside: Self.merged(restoring, before: current.setAside)
            )
            adopted = restoring
            return true
        }
        let restored = Self.tokens(for: restoring)
        if text.isEmpty || text == restoring.text {
            text = restoring.text
            tokens = restored
        } else {
            let shift = (restoring.text as NSString).length + 1
            tokens = restored + tokens.map { token in
                var moved = token
                moved.location += shift
                return moved
            }
            text = restoring.text + "\n" + text
        }
        caret = (text as NSString).length
        adopted = restoring
        return true
    }

    /// `restoring` first, then what was there on the next line, its mentions
    /// shifted - `adopt`'s own merge, on values.
    private static func merged(
        _ restoring: ComposedMessage,
        before kept: ComposedMessage
    ) -> ComposedMessage {
        guard !kept.text.isEmpty, kept.text != restoring.text else { return restoring }
        let shift = (restoring.text as NSString).length + 1
        let moved = kept.mentions
            .map { Mention(target: $0.target, start: $0.start + shift, length: $0.length) }
        return ComposedMessage(text: restoring.text + "\n" + kept.text, mentions: restoring.mentions + moved)
    }

    private static func tokens(for message: ComposedMessage) -> [Token] {
        let units = message.text as NSString
        return message.mentions.compactMap { mention in
            guard mention.start >= 0, mention.length > 1, mention.start + mention.length <= units.length,
                  units.character(at: mention.start) == 0x40 else { return nil }
            let name = units.substring(with: NSRange(location: mention.start + 1, length: mention.length - 1))
            return Token(location: mention.start, length: mention.length, target: mention.target, name: name)
        }
    }

    /// Whether `token`'s span still reads `@name` in `text`.
    private static func reads(_ token: Token, in text: String) -> Bool {
        let units = text as NSString
        guard token.location >= 0, token.end <= units.length else { return false }
        return units.substring(with: NSRange(location: token.location, length: token.length)) == "@" + token
            .name
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        UnicodeScalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
    }
}
