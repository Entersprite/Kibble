import Foundation

/// Markup for a composer that draws styles itself: what it edits instead of
/// markers, and how its spans and parsed markup combine.
public extension MessageMarkup {
    /// For a composer that draws the `shown` styles itself, bold as bold
    /// rather than as `**`: `message`'s text with only the markup it cannot
    /// draw (a list item's `- `), the `shown` spans in `content.formatting`
    /// addressing that text, and escapes only when the text would otherwise
    /// read as markup, so ordinary text comes back exactly as it was sent.
    /// `parse` turns the result back into `message`.
    static func editable(_ message: ComposedMessage, showing shown: Set<String>) -> ComposedMessage {
        let escaped = composable(message, showing: shown, escaping: true)
        let plain = composable(message, showing: shown, escaping: false)
        let reference = parse(escaped)
        let candidate = parse(plain)
        guard candidate.text == reference.text, candidate.mentions == reference.mentions,
              merged(candidate.content?.formatting ?? []) == merged(reference.content?.formatting ?? [])
        else { return escaped }
        return plain
    }

    /// Spans of one inline style that overlap or touch, as one span; other
    /// styles, such as a list's items, as they are. Ordered by start, the
    /// longer span first, so equal sets of spans compare equal.
    static func merged(_ formats: [MessageFormat]) -> [MessageFormat] {
        let inline = Set(delimiters.map(\.style))
        var result = formats.filter { !inline.contains($0.style) && $0.length > 0 }
        for style in inline {
            var current: MessageFormat?
            for format in formats.filter({ $0.style == style && $0.length > 0 })
                .sorted(by: { $0.start < $1.start }) {
                guard let open = current else { current = format; continue }
                if format.start <= open.start + open.length {
                    let end = max(open.start + open.length, format.start + format.length)
                    current = MessageFormat(style: style, start: open.start, length: end - open.start)
                } else {
                    result.append(open)
                    current = format
                }
            }
            if let current {
                result.append(current)
            }
        }
        return result.sorted { ($0.start, -$0.length, $0.style) < ($1.start, -$1.length, $1.style) }
    }

    /// `editable(_:showing:)`'s text, with every character that could read
    /// as markup escaped, or none.
    private static func composable(
        _ message: ComposedMessage,
        showing shown: Set<String>,
        escaping: Bool
    ) -> ComposedMessage {
        let formats = (message.content?.formatting ?? []).filter { $0.range(in: message.text) != nil }
        let source = message.text as NSString
        let items = Set(formats.filter { $0.style == "bulletItem" }.map(\.start))
        // Carried code is never parsed, so nothing in it needs an escape.
        let verbatim = formats
            .filter { shown.contains($0.style) && ($0.style == "code" || $0.style == "codeBlock") }
        var text = ""
        var textLength = 0
        func append(_ value: String) {
            text += value; textLength += value.utf16.count
        }
        var starts: [Int: Int] = [:]
        var ends: [Int: Int] = [:]
        var offset = 0
        for character in message.text {
            if items.contains(offset) {
                append("- ")
            }
            starts[offset] = textLength
            let literal = message.mentions.contains { $0.start <= offset && offset < $0.start + $0.length }
                || verbatim.contains { $0.start <= offset && offset < $0.start + $0.length }
            let literalBullet = character == "-" && (offset == 0 || source.character(at: offset - 1) == 10)
                && offset + 1 < source.length && source.character(at: offset + 1) == 32
            if escaping, !literal, literalBullet || "*`_~\\".contains(character) {
                append("\\")
            }
            append(String(character))
            offset += character.utf16.count
            ends[offset] = textLength
        }
        let spans = formats.filter { shown.contains($0.style) }.compactMap { format -> MessageFormat? in
            guard let start = starts[format.start], let end = ends[format.start + format.length], end > start
            else { return nil }
            return MessageFormat(style: format.style, start: start, length: end - start)
        }
        return ComposedMessage(
            text: text,
            mentions: editableMentions(message, starts: starts, ends: ends),
            content: MessageContent(formatting: spans, quote: message.content?.quote)
        )
    }
}
