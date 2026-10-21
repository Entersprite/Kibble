import ChatKit
import Foundation

public extension ComposerDraft {
    /// A style the field draws as itself, as Notes and Messages do: bold
    /// text is bold, never `**`. Raw values are the names `MessageFormat`
    /// sends. A list stays a typed `- ` line prefix: it shapes lines, and
    /// Messages has none to imitate.
    enum Style: String, CaseIterable, Sendable {
        case bold, italic, underline, strikethrough, code, codeBlock
    }

    /// `style` over `length` UTF-16 units from `location`, in the draft's
    /// own text, the unit `NSTextView` edits in and a token is measured in.
    struct Run: Equatable, Sendable {
        public var style: Style
        public var location: Int
        public var length: Int

        public init(style: Style, location: Int, length: Int) {
            self.style = style
            self.location = location
            self.length = length
        }

        public var end: Int {
            location + length
        }
    }

    /// What the next typed character looks like: the styles text typed at
    /// the caret takes.
    var typingStyles: Set<Style> {
        insertionStyles(location: caret, length: 0)
    }

    /// The styles text typed over `length` units at `location` takes, the
    /// way a Mac text view (Notes, TextEdit) picks them: the first replaced
    /// character's; at the caret, what Cmd-B and its kind chose there with
    /// nothing selected; otherwise the character before, so typing at the
    /// end of a bold word stays bold, except at the start of a line, which
    /// takes the line's first character, as AppKit does (measured on
    /// macOS 27).
    func insertionStyles(location: Int, length: Int) -> Set<Style> {
        let units = text as NSString
        if length > 0, location < units.length {
            return ComposerRuns.styles(at: location, in: runs)
        }
        if let typingOverride, location == caret {
            return typingOverride
        }
        guard location > 0, location <= units.length else {
            return units.length > 0 ? ComposerRuns.styles(at: 0, in: runs) : []
        }
        if ComposerRuns.isLineBreak(units.character(at: location - 1)), location < units.length,
           !ComposerRuns.isLineBreak(units.character(at: location)) {
            return ComposerRuns.styles(at: location, in: runs)
        }
        return ComposerRuns.styles(at: location - 1, in: runs)
    }

    /// The styles to show as on for `selection`, as Notes checks them in its
    /// Format menu: the typing styles with nothing selected, otherwise those
    /// every selected character has.
    func activeStyles(in selection: NSRange) -> Set<Style> {
        guard selection.length > 0 else { return typingStyles }
        return Set(Style.allCases.filter { ComposerRuns.covers($0, selection, in: text, runs: runs) })
    }

    /// Cmd-B and its kind, as in Notes. Over a selection, `style` goes on
    /// unless every selected character has it already, and then comes off;
    /// a code block takes whole lines, so with nothing selected it takes
    /// the caret's line. Otherwise, with nothing selected, it changes the
    /// style the next typed text takes, until the caret moves.
    ///
    /// Returns the range whose characters changed, or `nil` when only the
    /// typing style did.
    @discardableResult
    mutating func toggle(_ style: Style, in selection: NSRange) -> NSRange? {
        let units = text as NSString
        let location = min(max(0, selection.location), units.length)
        let length = min(max(0, selection.length), units.length - location)
        var range = NSRange(location: location, length: length)
        if style == .codeBlock {
            range = units.lineRange(for: range)
        }
        let hasText = (range.location ..< NSMaxRange(range))
            .contains { !ComposerRuns.isLineBreak(units.character(at: $0)) }
        guard range.length > 0, style != .codeBlock || hasText else {
            moveCaret(to: location)
            typingOverride = typingStyles.symmetricDifference([style])
            return nil
        }
        let on = !ComposerRuns.covers(style, range, in: text, runs: runs)
        runs = ComposerRuns.setting(style, on, over: range, in: runs)
        return range
    }

    /// `message`, sent or failed, as the field edits it. With `formatting`,
    /// its spans become runs where the field draws them (the macOS text
    /// view) and markup where it cannot (the `TextField` elsewhere), and a
    /// list keeps its typed `- ` either way.
    internal static func loaded(
        _ message: ComposedMessage,
        formatting: Bool
    ) -> (message: ComposedMessage, runs: [Run]) {
        guard formatting else {
            let quote = MessageContent(quote: message.content?.quote)
            return (ComposedMessage(text: message.text, mentions: message.mentions, content: quote), [])
        }
        #if os(macOS)
            let editable = MessageMarkup.editable(message, showing: Set(Style.allCases.map(\.rawValue)))
            return (editable, runs(for: editable))
        #else
            return (MessageMarkup.editable(message), [])
        #endif
    }

    /// The runs a value carries as spans over its own text, as a set-aside
    /// or loaded draft holds them.
    internal static func runs(for message: ComposedMessage) -> [Run] {
        ComposerRuns.runs(from: message.content?.formatting ?? [], length: (message.text as NSString).length)
    }
}

/// The arithmetic of formatting runs, as pure functions on values, apart
/// for `ComposerDraft.swift`'s length.
enum ComposerRuns {
    typealias Run = ComposerDraft.Run
    typealias Style = ComposerDraft.Style

    /// One run per stretch of a style: overlapping and touching runs of one
    /// style become one, and empty runs go. Ordered by location, then style,
    /// so two equal formattings are equal arrays.
    static func normalized(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for style in Style.allCases {
            var current: Run?
            for run in runs.filter({ $0.style == style && $0.length > 0 })
                .sorted(by: { $0.location < $1.location }) {
                guard var open = current else { current = run; continue }
                if run.location <= open.end {
                    open.length = max(open.end, run.end) - open.location
                    current = open
                } else {
                    result.append(open)
                    current = run
                }
            }
            if let current {
                result.append(current)
            }
        }
        let order = Style.allCases
        return result.sorted {
            ($0.location, order.firstIndex(of: $0.style) ?? 0) < (
                $1.location,
                order.firstIndex(of: $1.style) ?? 0
            )
        }
    }

    /// The styles of the character at `offset`.
    static func styles(at offset: Int, in runs: [Run]) -> Set<Style> {
        Set(runs.filter { $0.location <= offset && offset < $0.end }.map(\.style))
    }

    /// The runs after `length` units at `location` are replaced by
    /// `inserted` units carrying `styles`: runs before stay, runs after move,
    /// a run the edit removes text from shrinks, and a run the insertion
    /// lands inside is split around it unless the insertion has its style.
    static func replacing(
        _ runs: [Run],
        location: Int,
        length: Int,
        inserted: Int,
        styles: Set<Style>
    ) -> [Run] {
        var result: [Run] = []
        for run in runs {
            /// Positions after the removed text move back to `location`.
            func moved(_ offset: Int) -> Int {
                offset <= location ? offset : max(location, offset - length)
            }
            let start = moved(run.location)
            let stop = moved(run.end)
            if stop <= location {
                result.append(Run(style: run.style, location: start, length: stop - start))
            } else if start >= location {
                // At or after the edit, including a run that starts where
                // the insertion lands: the inserted text goes before it.
                result.append(Run(style: run.style, location: start + inserted, length: stop - start))
            } else {
                // The run spans the edit: what is left on each side of it.
                result.append(Run(style: run.style, location: start, length: location - start))
                result.append(Run(style: run.style, location: location + inserted, length: stop - location))
            }
        }
        for style in styles where inserted > 0 {
            result.append(Run(style: style, location: location, length: inserted))
        }
        return normalized(result)
    }

    /// `runs` with `style` added over `range`, or taken off it.
    static func setting(_ style: Style, _ on: Bool, over range: NSRange, in runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs {
            guard run.style == style, run.location < NSMaxRange(range), range.location < run.end else {
                result.append(run)
                continue
            }
            result.append(Run(style: style, location: run.location, length: range.location - run.location))
            result.append(Run(style: style, location: NSMaxRange(range), length: run.end - NSMaxRange(range)))
        }
        if on {
            result.append(Run(style: style, location: range.location, length: range.length))
        }
        return normalized(result)
    }

    /// Whether every character in `range` has `style`. Line breaks are not
    /// asked, so two bold lines selected together count as bold, unless the
    /// range holds nothing else.
    static func covers(_ style: Style, _ range: NSRange, in text: String, runs: [Run]) -> Bool {
        let units = text as NSString
        let offsets = (range.location ..< NSMaxRange(range)).filter { $0 < units.length }
        let asked = offsets.filter { !isLineBreak(units.character(at: $0)) }
        return (asked.isEmpty ? offsets : asked).allSatisfy { styles(at: $0, in: runs).contains(style) }
    }

    /// Runs read from spans over a text of `length` units: known styles
    /// only, cut to the text.
    static func runs(from formats: [MessageFormat], length: Int) -> [Run] {
        normalized(formats.compactMap { format in
            guard let style = Style(rawValue: format.style) else { return nil }
            let start = max(0, format.start)
            let end = min(length, format.start + format.length)
            guard end > start else { return nil }
            return Run(style: style, location: start, length: end - start)
        })
    }

    static func formats(_ runs: [Run]) -> [MessageFormat] {
        runs.map { MessageFormat(style: $0.style.rawValue, start: $0.location, length: $0.length) }
    }

    static func shifted(_ runs: [Run], by shift: Int) -> [Run] {
        runs.map { Run(style: $0.style, location: $0.location + shift, length: $0.length) }
    }

    /// What Send sends of each run, over the trimmed text that starts at
    /// `start` and ends at `end` in the draft: cut to it and moved to its
    /// offsets. A code block also loses the line breaks at its ends, which
    /// it holds when its lines were chosen whole.
    ///
    /// Each span is widened to whole characters. A style can change inside
    /// one (an accent typed after a bold letter with bold turned off), and
    /// a span that starts or ends inside a character is refused at send
    /// (`MessageContent.validate`), so the message would fail.
    static func sent(_ runs: [Run], in text: String, from start: Int, to end: Int) -> [MessageFormat] {
        let units = text as NSString
        var boundaries = [start]
        for character in units.substring(with: NSRange(location: start, length: end - start)) {
            boundaries.append(boundaries[boundaries.count - 1] + character.utf16.count)
        }
        return runs.compactMap { run in
            var lower = max(run.location, start)
            var upper = min(run.end, end)
            if run.style == .codeBlock {
                while lower < upper, isLineBreak(units.character(at: lower)) {
                    lower += 1
                }
                while upper > lower, isLineBreak(units.character(at: upper - 1)) {
                    upper -= 1
                }
            }
            guard upper > lower else { return nil }
            lower = boundaries.last { $0 <= lower } ?? start
            upper = boundaries.first { $0 >= upper } ?? end
            return MessageFormat(style: run.style.rawValue, start: lower - start, length: upper - lower)
        }
    }

    static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }
}
