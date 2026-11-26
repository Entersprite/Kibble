import ChatKit
import Foundation

public extension ComposerDraft {
    /// The shortcode remains editable text; its typed reference survives only
    /// while that exact text remains, as with a picked mention.
    mutating func insertEmoji(_ choice: ReactionChoice, replacing range: NSRange? = nil) {
        let range = range ?? NSRange(location: caret, length: 0)
        replace(location: range.location, length: range.length, with: choice.emoji)
        if let emoji = choice.customEmoji {
            customEmoji.append(MessageCustomEmoji(
                emoji: emoji,
                start: range.location,
                length: choice.emoji.utf16.count
            ))
            customEmoji.sort { $0.start < $1.start }
        }
    }

    /// With `formatting`, the runs go as spans over the trimmed text, and
    /// any markup typed by hand (`**bold**`) is still read
    /// (`MessageMarkup.parse`), the spans of one style merged. Without it,
    /// the runs are not sent.
    func composed(formatting: Bool = false) -> ComposedMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty
        else { return ComposedMessage(text: "", content: MessageContent(quote: quote)) }
        // `trimmed` starts at the first non-whitespace unit, so its first
        // occurrence is where the trim began.
        let start = (text as NSString).range(of: trimmed).location
        let end = start + (trimmed as NSString).length
        let mentions = tokens
            .filter { $0.location >= start && $0.end <= end && Self.reads($0, in: text) }
            .map { Mention(target: $0.target, start: $0.location - start, length: $0.length) }
        let emoji = customEmoji
            .filter { $0.range(in: text) != nil && $0.start >= start && $0.start + $0.length <= end }
            .map { $0.shifted(by: -start) }
        guard formatting else {
            return ComposedMessage(
                text: trimmed,
                mentions: mentions,
                content: MessageContent(customEmoji: emoji, quote: quote)
            )
        }
        var message = MessageMarkup.parse(ComposedMessage(
            text: trimmed,
            mentions: mentions,
            content: MessageContent(
                formatting: ComposerRuns.sent(runs, in: text, from: start, to: end),
                customEmoji: emoji,
                quote: quote
            )
        ))
        let formats = message.content?.formatting ?? []
        message.content?.formatting = MessageMarkup.merged(formats)
        return message
    }
}
