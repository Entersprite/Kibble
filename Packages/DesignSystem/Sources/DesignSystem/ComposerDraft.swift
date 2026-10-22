import ChatKit
import Foundation

/// The composer's draft: its text, the mention tokens and formatting runs in
/// it, and the caret. The decisions worth testing live here, and the views
/// only route into it.
///
/// A value type because this package's rule is that views take values and hand
/// back callbacks: a `@State String` inside `Composer` is not reachable from a
/// test. `ConnectionBanner.offersReconnect(for:)` is the shape this follows.
///
/// **Offsets are UTF-16 code units**, the unit `NSTextView` edits in and the
/// unit Google's mention spans count (`findings.md` §41.1), so a token's range
/// is a `Mention`'s span with no conversion.
///
/// Formatting is kept the way tokens are: as runs over the text
/// (`ComposerDraft+Runs`), moved by every edit, and sent as spans, so the
/// field draws bold as bold and never as `**`.
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
    public internal(set) var customEmoji: [MessageCustomEmoji] = []
    public private(set) var tokens: [Token] = []
    /// The formatting, normalized (`ComposerRuns.normalized`). Set within
    /// this module only by the edits here and `toggle`.
    public internal(set) var runs: [Run] = []
    /// The styles chosen for the next typed text with nothing selected
    /// (Cmd-B at the caret), until the text is typed or the caret moves.
    public internal(set) var typingOverride: Set<Style>?
    public private(set) var caret = 0
    public private(set) var quote: MessageQuote?
    private var adopted: ComposedMessage?

    /// The message being edited, when the field holds one (edit spec §5).
    public struct Editing: Equatable, Sendable {
        public let messageID: Message.ID
        /// What the field held before the edit began, given back when it ends.
        let setAside: ComposedMessage
    }

    public private(set) var editing: Editing?

    public init() {}

    /// A saved draft. One saved before the composer drew styles has no
    /// formatting, and loads as it always did.
    public init(snapshot: ComposerSnapshot) {
        self.init()
        quote = snapshot.quote
        text = snapshot.text
        customEmoji = snapshot.customEmoji.filter { $0.range(in: snapshot.text) != nil }
        tokens = Self.tokens(for: ComposedMessage(text: snapshot.text, mentions: snapshot.mentions))
        runs = ComposerRuns.runs(from: snapshot.formatting, length: (text as NSString).length)
        moveCaret(to: snapshot.caret)
    }

    public func snapshot(at address: ComposerDraftAddress) -> ComposerSnapshot {
        let draft = compositionOnly
        return ComposerSnapshot(
            conversation: address.conversation, thread: address.thread,
            text: draft.text, mentions: draft.untrimmedMentions(), caret: draft.caret, quote: draft.quote,
            formatting: ComposerRuns.formats(draft.runs), customEmoji: draft.customEmoji
        )
    }

    /// A destroyed composer cancels its edit. Keep the unsent composition it
    /// set aside, so edited message text cannot become a new outgoing draft.
    public var compositionOnly: ComposerDraft {
        var copy = self
        _ = copy.endEditing()
        return copy
    }

    /// The whole text replaced at once: `TextField`'s binding, or what
    /// Writing Tools wrote in the text view while it ran. Tokens survive
    /// only where the new text still reads `@name` at their offsets. Runs
    /// keep the text the two share at each end, and what changed between
    /// comes in plain: a rewrite (Writing Tools) drops the styles of what it
    /// rewrote rather than guessing them.
    public mutating func edit(_ text: String) {
        let old = Array(self.text)
        let new = Array(text)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let units = { (characters: ArraySlice<Character>) in characters.reduce(0) { $0 + $1.utf16.count } }
        let location = units(old[..<prefix])
        runs = ComposerRuns.replacing(
            runs, location: location,
            length: units(old[prefix ..< old.count - suffix]),
            inserted: units(new[prefix ..< new.count - suffix]),
            styles: []
        )
        customEmoji = MessageCustomEmoji.replacing(
            customEmoji,
            location: location,
            length: units(old[prefix ..< old.count - suffix]),
            inserted: units(new[prefix ..< new.count - suffix])
        )
        self.text = text
        customEmoji = customEmoji.filter { $0.range(in: text) != nil }
        tokens = tokens.filter { Self.reads($0, in: text) }
        typingOverride = nil
        caret = (text as NSString).length
    }

    /// The text view's text and formatting, after a change the edit routing
    /// did not describe: an undo or a redo, which brings styles back with
    /// the text they were on, or an input method's composition. Tokens as
    /// `edit(_:)` keeps them.
    mutating func follow(_ text: String, runs: [Run], customEmoji: [MessageCustomEmoji]? = nil) {
        if text != self.text {
            self.text = text
            tokens = tokens.filter { Self.reads($0, in: text) }
            caret = (text as NSString).length
        }
        self.customEmoji = (customEmoji ?? self.customEmoji).filter { $0.range(in: text) != nil }
        self.runs = ComposerRuns.runs(from: ComposerRuns.formats(runs), length: (text as NSString).length)
        typingOverride = nil
    }

    /// Moving the caret anywhere else forgets a style chosen for typing, as
    /// a Mac text view does.
    public mutating func moveCaret(to offset: Int) {
        let moved = min(max(0, offset), (text as NSString).length)
        if moved != caret {
            typingOverride = nil
        }
        caret = moved
    }

    /// One edit, as `NSTextView` reports it. Tokens wholly before it stay,
    /// tokens wholly after it move, and a token the edit touches becomes plain
    /// text, so a mention is never sent whose text no longer names the person.
    /// Runs move the same way, and the inserted text takes `styles`, by
    /// default the ones typing there takes (`insertionStyles`).
    public mutating func replace(
        location: Int,
        length: Int,
        with string: String,
        styles: Set<Style>? = nil
    ) {
        let inserted = (string as NSString).length
        customEmoji = MessageCustomEmoji.replacing(
            customEmoji,
            location: location,
            length: length,
            inserted: inserted
        )
        let applied = styles ?? insertionStyles(location: location, length: length)
        runs = ComposerRuns.replacing(
            runs, location: location, length: length, inserted: inserted, styles: applied
        )
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
        typingOverride = nil
        caret = location + inserted
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
    public mutating func setQuote(_ quote: MessageQuote?) {
        guard editing == nil else { return }
        self.quote = quote
    }

    /// Puts the field aside and loads `message`, tokens and all, with the
    /// caret at the end. Beginning again while editing keeps the first
    /// set-aside draft: the previous edit's text is not the person's draft.
    public mutating func beginEditing(
        _ messageID: Message.ID,
        with message: ComposedMessage,
        formatting: Bool = false
    ) {
        let setAside = editing?.setAside ?? composition
        let loaded = Self.loaded(message, formatting: formatting)
        text = loaded.message.text
        customEmoji = loaded.message.content?.customEmoji ?? []
        tokens = Self.tokens(for: loaded.message)
        runs = loaded.runs
        typingOverride = nil
        quote = message.content?.quote
        caret = (text as NSString).length
        editing = Editing(messageID: messageID, setAside: setAside)
    }

    /// Ends the edit, saved or cancelled: hands back what the field held,
    /// and puts the set-aside draft back. `nil` when nothing was being edited.
    public mutating func endEditing(formatting: Bool = false)
        -> (messageID: Message.ID, message: ComposedMessage)? {
        guard let editing else { return nil }
        let edited = composed(formatting: formatting)
        self.editing = nil
        quote = editing.setAside.content?.quote
        text = editing.setAside.text
        customEmoji = editing.setAside.content?.customEmoji ?? []
        tokens = Self.tokens(for: editing.setAside)
        runs = Self.runs(for: editing.setAside)
        typingOverride = nil
        caret = (text as NSString).length
        return (editing.messageID, edited)
    }

    /// The field as a value, untrimmed, its runs as spans over its own text:
    /// what an edit sets aside.
    private var composition: ComposedMessage {
        ComposedMessage(
            text: text,
            mentions: untrimmedMentions(),
            content: MessageContent(
                formatting: ComposerRuns.formats(runs),
                customEmoji: customEmoji,
                quote: quote
            )
        )
    }

    /// The tokens as mentions at their own offsets, untrimmed, so a set-aside
    /// draft comes back exactly as it was typed.
    private func untrimmedMentions() -> [Mention] {
        tokens.filter { Self.reads($0, in: text) }
            .map { Mention(target: $0.target, start: $0.location, length: $0.length) }
    }

    public mutating func clear() {
        text = ""
        customEmoji = []
        tokens = []
        runs = []
        typingOverride = nil
        caret = 0
        quote = nil
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
    public mutating func adopt(_ restoring: ComposedMessage?, formatting: Bool = false) -> Bool {
        guard let original = restoring, !original.text.isEmpty else {
            adopted = nil
            return false
        }
        guard original != adopted else { return false }
        let loaded = Self.loaded(original, formatting: formatting)
        let restoring = loaded.message
        if let current = editing {
            // Never merged into the message being edited: it goes with the
            // set-aside draft, and is there when the edit ends.
            editing = Editing(
                messageID: current.messageID,
                setAside: Self.merged(restoring, runs: loaded.runs, before: current.setAside)
            )
            adopted = original
            return true
        }
        if let quote = restoring.content?.quote {
            self.quote = quote
        }
        let restored = Self.tokens(for: restoring)
        if text.isEmpty || text == restoring.text {
            text = restoring.text
            customEmoji = restoring.content?.customEmoji ?? []
            tokens = restored
            runs = loaded.runs
        } else {
            let shift = (restoring.text as NSString).length + 1
            customEmoji = (restoring.content?.customEmoji ?? []) + customEmoji.map { $0.shifted(by: shift) }
            tokens = restored + tokens.map { token in
                var moved = token
                moved.location += shift
                return moved
            }
            runs = ComposerRuns.normalized(loaded.runs + ComposerRuns.shifted(runs, by: shift))
            text = restoring.text + "\n" + text
        }
        typingOverride = nil
        caret = (text as NSString).length
        adopted = original
        return true
    }

    /// `restoring` first, then what was there on the next line, its mentions
    /// and runs shifted - `adopt`'s own merge, on values.
    private static func merged(
        _ restoring: ComposedMessage,
        runs: [Run],
        before kept: ComposedMessage
    ) -> ComposedMessage {
        guard !kept.text.isEmpty, kept.text != restoring.text else {
            let formatting = ComposerRuns.formats(runs)
            return ComposedMessage(
                text: restoring.text, mentions: restoring.mentions,
                content: MessageContent(
                    formatting: formatting,
                    customEmoji: restoring.content?.customEmoji ?? [],
                    quote: restoring.content?.quote
                )
            )
        }
        let quote = restoring.content?.quote ?? kept.content?.quote
        let shift = (restoring.text as NSString).length + 1
        let moved = kept.mentions
            .map { Mention(target: $0.target, start: $0.start + shift, length: $0.length) }
        let keptRuns = ComposerRuns.shifted(Self.runs(for: kept), by: shift)
        return ComposedMessage(
            text: restoring.text + "\n" + kept.text, mentions: restoring.mentions + moved,
            content: MessageContent(
                formatting: ComposerRuns.formats(runs + keptRuns),
                customEmoji: (restoring.content?.customEmoji ?? []) +
                    (kept.content?.customEmoji ?? []).map { $0.shifted(by: shift) },
                quote: quote
            )
        )
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
    static func reads(_ token: Token, in text: String) -> Bool {
        let units = text as NSString
        guard token.location >= 0, token.end <= units.length else { return false }
        return units.substring(with: NSRange(location: token.location, length: token.length)) == "@" + token
            .name
    }
}
