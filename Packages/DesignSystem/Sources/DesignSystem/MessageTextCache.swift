#if os(macOS)
    import AppKit
    import ChatKit

    /// One formatted value per live text view. Menu and reaction updates
    /// still reach the coordinator, but do not repeat link detection.
    @MainActor
    final class MessageTextCache {
        private struct Input: Equatable {
            let text: String
            let mentions: [Mention]
            let links: [MessageLink]
            let me: Member.ID?
            let inOwnBubble: Bool
            let font: NSFont
            let accent: NSColor
        }

        private var previous: Input?
        private var formatted: NSAttributedString?

        func attributed(message: Message, me: Member.ID?, inOwnBubble: Bool) -> NSAttributedString {
            let input = Input(
                text: message.text, mentions: message.mentions, links: message.links,
                me: me, inOwnBubble: inOwnBubble,
                font: NSFont.preferredFont(forTextStyle: .body), accent: .controlAccentColor
            )
            if input == previous, let formatted {
                return formatted
            }
            let text = MessageTextAttributes.attributed(
                input.text, mentions: input.mentions, links: input.links,
                me: me, inOwnBubble: inOwnBubble
            )
            previous = input
            formatted = text
            return text
        }
    }
#endif
