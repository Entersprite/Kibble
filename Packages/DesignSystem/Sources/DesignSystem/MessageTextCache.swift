#if os(macOS)
    import AppKit
    import ChatKit

    /// Formatting survives row recreation. Every formatting input participates
    /// in exact equality; a hash collision can never return another message.
    @MainActor
    final class MessageTextCache {
        static let shared = MessageTextCache()

        private struct Input: Hashable {
            let text: String
            let mentions: [Mention]
            let links: [MessageLink]
            let me: Member.ID?
            let inOwnBubble: Bool
            let font: NSFont
            let accent: NSColor
            let foreground: NSColor
        }

        private let cache: BoundedRenderingCache<Input, NSAttributedString>
        private(set) var misses = 0

        init(costLimit: Int = 24 * 1024 * 1024, countLimit: Int = 2000) {
            cache = BoundedRenderingCache(costLimit: costLimit, countLimit: countLimit)
        }

        func attributed(
            message: Message, me: Member.ID?, inOwnBubble: Bool,
            font: NSFont = .preferredFont(forTextStyle: .body),
            accent: NSColor = .controlAccentColor
        ) -> NSAttributedString {
            let input = Input(
                text: message.text, mentions: message.mentions, links: message.links,
                me: me, inOwnBubble: inOwnBubble, font: font, accent: accent,
                foreground: inOwnBubble ? .white : .labelColor
            )
            if let formatted = cache.value(for: input) {
                return formatted
            }
            misses += 1
            let text = NSAttributedString(attributedString: MessageTextAttributes.attributed(
                input.text, mentions: input.mentions, links: input.links,
                me: me, inOwnBubble: inOwnBubble, font: font, accent: accent
            ))
            // Conservatively price copied keys, UTF-16 text and attribute runs.
            let cost = 512 + text.length * 8 + (message.mentions.count + message.links.count) * 256
            cache.insert(text, for: input, cost: cost)
            return text
        }

        func removeAll() {
            cache.removeAll()
            misses = 0
        }
    }
#endif
