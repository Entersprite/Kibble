import Foundation

/// Small, deterministic composition syntax. Delimiters never enter a mention
/// token, and all returned spans address the resulting UTF-16 text.
public enum MessageMarkup {
    public static let delimiters: [(marker: String, style: String)] = [
        ("```", "codeBlock"), ("**", "bold"), ("__", "underline"),
        ("~~", "strikethrough"), ("`", "code"), ("*", "italic")
    ]

    public static func canEdit(_ content: MessageContent?) -> Bool {
        let known = Set(delimiters.map(\.style) + ["bulletItem", "bulletList"])
        return content?.formatting.allSatisfy { known.contains($0.style) } ?? true
    }

    public static func parse(_ message: ComposedMessage) -> ComposedMessage {
        var parser = Parser(message)
        parser.read(0 ..< parser.characters.count, depth: 0)
        let mentions = message.mentions.compactMap { mention -> Mention? in
            guard mention.start >= 0, mention.length > 0,
                  mention.start <= parser.map.count - 1,
                  mention.length < parser.map.count - mention.start else { return nil }
            let start = parser.map[mention.start]
            let end = parser.map[mention.start + mention.length]
            guard start >= 0, end > start else { return nil }
            return Mention(target: mention.target, start: start, length: end - start, mode: mention.mode)
        }
        let content = MessageContent(formatting: parser.formats, quote: message.content?.quote)
        return ComposedMessage(text: parser.output, mentions: mentions, content: content)
    }

    /// Used when editing/restoring formatted text. Ordinary drafts retain the
    /// typed syntax, so reopening never reparses or silently sends anything.
    public static func editable(_ message: ComposedMessage) -> ComposedMessage {
        let formats = (message.content?.formatting ?? []).filter { $0.range(in: message.text) != nil }
        let source = message.text as NSString
        let boundaries = Set([0, source.length] + formats.flatMap { [$0.start, $0.start + $0.length] })
            .sorted()
        var text = ""
        var textLength = 0
        func append(_ value: String) {
            text += value; textLength += value.utf16.count
        }
        var starts: [Int: Int] = [:]
        var ends: [Int: Int] = [:]
        var active: [String] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let styles = delimiters.filter { delimiter in
                formats
                    .contains {
                        $0.style == delimiter.style && $0.start <= start && $0.start + $0.length >= end
                    }
            }
            let desired = styles.map(\.marker)
            let shared = zip(active, desired).prefix { $0 == $1 }.count
            append(active.dropFirst(shared).reversed().joined())
            if formats.contains(where: { $0.style == "bulletItem" && $0.start == start }) {
                append("- ")
            }
            append(desired.dropFirst(shared).joined())
            active = desired
            var offset = start
            let code = styles.contains { $0.style == "code" || $0.style == "codeBlock" }
            for character in source.substring(with: NSRange(location: start, length: end - start)) {
                starts[offset] = textLength
                let mentioned = message.mentions
                    .contains { $0.start <= offset && offset < $0.start + $0.length }
                let literalBullet = !code && character == "-" &&
                    (offset == 0 || source.character(at: offset - 1) == 10)
                    && offset + 1 < source.length && source.character(at: offset + 1) == 32
                if !mentioned, literalBullet || (code ? "`\\" : "*`_~\\").contains(character) {
                    append("\\")
                }
                append(String(character))
                offset += character.utf16.count
                ends[offset] = textLength
            }
        }
        append(active.reversed().joined())

        return ComposedMessage(
            text: text,
            mentions: editableMentions(message, starts: starts, ends: ends),
            content: MessageContent(quote: message.content?.quote)
        )
    }

    private static func editableMentions(
        _ message: ComposedMessage,
        starts: [Int: Int],
        ends: [Int: Int]
    ) -> [Mention] {
        message.mentions.compactMap { mention -> Mention? in
            guard let start = starts[mention.start], let end = ends[mention.start + mention.length],
                  end > start
            else { return nil }
            return Mention(target: mention.target, start: start, length: end - start, mode: mention.mode)
        }
    }

    private struct Parser {
        let original: ComposedMessage
        let characters: [Character]
        let offsets: [Int]
        var map: [Int]
        var output = ""
        var outputLength = 0
        var formats: [MessageFormat] = []

        init(_ message: ComposedMessage) {
            original = message
            characters = Array(message.text)
            var positions = [0]
            var offset = 0
            for character in characters {
                offset += character.utf16.count
                positions.append(offset)
            }
            offsets = positions
            map = Array(repeating: -1, count: message.text.utf16.count + 1)
        }

        mutating func skip(_ range: Range<Int>) {
            for index in offsets[range.lowerBound] ... offsets[range.upperBound] {
                map[index] = outputLength
            }
        }

        mutating func append(_ range: Range<Int>) {
            for index in range {
                let position = outputLength
                for unit in 0 ..< characters[index].utf16
                    .count {
                    map[offsets[index] + unit] = position + unit
                }
                output.append(characters[index])
                outputLength += characters[index].utf16.count
                map[offsets[index + 1]] = outputLength
            }
        }

        mutating func read(_ range: Range<Int>, depth: Int) {
            guard depth < 32 else { append(range); return }
            var index = range.lowerBound
            while index < range.upperBound {
                if let end = readBullet(at: index, end: range.upperBound, depth: depth) {
                    index = end
                    continue
                }
                if !inMention(index), characters[index] == "\\", index + 1 < range.upperBound,
                   "*`_~\\-".contains(characters[index + 1]) {
                    skip(index ..< index + 1)
                    append(index + 1 ..< index + 2)
                    index += 2
                    continue
                }
                var matched = false
                for delimiter in MessageMarkup.delimiters {
                    let marker = Array(delimiter.marker)
                    let count = marker.count
                    guard matches(marker, at: index, end: range.upperBound), !inMention(index),
                          let close = closing(marker, from: index + count, end: range.upperBound),
                          close > index + count else { continue }
                    skip(index ..< index + count)
                    let start = outputLength
                    if delimiter.style == "code" || delimiter.style == "codeBlock" {
                        appendCode(index + count ..< close)
                    } else {
                        read(index + count ..< close, depth: depth + 1)
                    }
                    let length = outputLength - start
                    skip(close ..< close + count)
                    formats.append(MessageFormat(style: delimiter.style, start: start, length: length))
                    index = close + count
                    matched = true
                    break
                }
                if !matched {
                    append(index ..< index + 1); index += 1
                }
            }
        }

        mutating func readBullet(at index: Int, end limit: Int, depth: Int) -> Int? {
            if !inMention(index), index == 0 || characters[index - 1] == "\n", index + 1 < limit,
               characters[index] == "-" || characters[index] == "*", characters[index + 1] == " " {
                let end = (index + 2 ..< limit).first { characters[$0] == "\n" } ?? limit
                skip(index ..< index + 2)
                let start = outputLength
                read(index + 2 ..< end, depth: depth + 1)
                if outputLength > start {
                    formats.append(MessageFormat(
                        style: "bulletItem",
                        start: start,
                        length: outputLength - start
                    ))
                }
                return end
            }
            return nil
        }

        mutating func appendCode(_ range: Range<Int>) {
            var index = range.lowerBound
            while index < range.upperBound {
                if !inMention(index), characters[index] == "\\", index + 1 < range.upperBound,
                   "`\\".contains(characters[index + 1]) {
                    skip(index ..< index + 1)
                    index += 1
                }
                append(index ..< index + 1)
                index += 1
            }
        }

        func matches(_ marker: [Character], at start: Int, end: Int) -> Bool {
            start + marker.count <= end && Array(characters[start ..< start + marker.count]) == marker
        }

        func inMention(_ index: Int) -> Bool {
            original.mentions.contains { $0.start <= offsets[index] && offsets[index] < $0.start + $0.length }
        }

        func closing(_ marker: [Character], from start: Int, end: Int) -> Int? {
            var index = start
            while index + marker.count <= end {
                if characters[index] == "\\" {
                    index += 2; continue
                }
                if !inMention(index), matches(marker, at: index, end: end) {
                    if marker.first == "*" {
                        var stop = index
                        while stop < end, characters[stop] == "*" {
                            stop += 1
                        }
                        let run = stop - index
                        if marker.count == 1, run.isMultiple(of: 2) {
                            index = stop; continue
                        }
                        return stop - marker.count
                    }
                    return index
                }
                index += 1
            }
            return nil
        }
    }
}
