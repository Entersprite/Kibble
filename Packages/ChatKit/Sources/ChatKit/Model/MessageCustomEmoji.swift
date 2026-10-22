import Foundation

/// An uploaded emoji over its fallback text, in UTF-16 units like mentions.
/// Older clients retain readable shortcodes when they ignore this metadata.
public struct MessageCustomEmoji: Codable, Hashable, Sendable {
    public var emoji: CustomEmojiRef
    public var start: Int
    public var length: Int

    public init(emoji: CustomEmojiRef, start: Int, length: Int) {
        self.emoji = emoji
        self.start = start
        self.length = length
    }

    public func range(in text: String) -> Range<String.Index>? {
        guard !emoji.id.isEmpty, !emoji.shortcode.isEmpty,
              let range = MessageFormat(style: "", start: start, length: length).range(in: text),
              String(text[range]) == emoji.displayText else { return nil }
        return range
    }

    public func shifted(by offset: Int) -> Self {
        let (moved, overflow) = start.addingReportingOverflow(offset)
        return Self(emoji: emoji, start: overflow ? -1 : moved, length: length)
    }

    /// Keep untouched spans, move those after an edit, and drop touched spans.
    public static func replacing(
        _ spans: [Self], location: Int, length: Int, inserted: Int
    ) -> [Self] {
        let (end, overflow) = location.addingReportingOverflow(length)
        guard location >= 0, length >= 0, inserted >= 0, !overflow else { return [] }
        return spans.compactMap { span in
            let (spanEnd, overflow) = span.start.addingReportingOverflow(span.length)
            guard span.start >= 0, span.length > 0, !overflow else { return nil }
            if spanEnd <= location {
                return span
            }
            if span.start >= end {
                return span.shifted(by: inserted - length)
            }
            return nil
        }
    }
}
