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
            let formatting: [MessageFormat]
            let customEmoji: [MessageCustomEmoji]
            let emojiImages: [CustomEmojiRef: Data]
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
            accent: NSColor = .controlAccentColor,
            emojiImages: [CustomEmojiRef: Data] = [:]
        ) -> NSAttributedString {
            let input = Input(
                text: message.text, mentions: message.mentions, links: message.links,
                formatting: message.content?.formatting ?? [],
                customEmoji: message.content?.customEmoji ?? [], emojiImages: emojiImages,
                me: me, inOwnBubble: inOwnBubble, font: font, accent: accent,
                foreground: inOwnBubble ? .white : .labelColor
            )
            if let formatted = cache.value(for: input) {
                return formatted
            }
            misses += 1
            let text = NSMutableAttributedString(attributedString: MessageTextAttributes.attributed(
                input.text, mentions: input.mentions, links: input.links,
                formatting: input.formatting,
                me: me, inOwnBubble: inOwnBubble, font: font, accent: accent
            ))
            var nextStart = input.text.utf16.count
            for span in input.customEmoji.sorted(by: { $0.start > $1.start }) {
                guard span.range(in: input.text) != nil, span.start + span.length <= nextStart,
                      let data = input.emojiImages[span.emoji], let bitmap = ReactionDisplay.image(from: data)
                else { continue }
                nextStart = span.start
                let size = input.font.pointSize * 1.3
                let image = NSImage(cgImage: bitmap, size: NSSize(width: size, height: size))
                let attachment = NSTextAttachment()
                attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
                attachment.bounds = NSRect(x: 0, y: input.font.descender, width: size, height: size)
                text.replaceCharacters(
                    in: NSRange(location: span.start, length: span.length),
                    with: NSAttributedString(attachment: attachment)
                )
            }
            // Conservatively price copied keys, UTF-16 text and attribute runs.
            let cost = 512 + text.length * 8 + (message.mentions.count + message.links.count) * 256
                + emojiImages.values.reduce(0) { $0 + $1.count }
            let immutable = NSAttributedString(attributedString: text)
            cache.insert(immutable, for: input, cost: cost)
            return immutable
        }

        func removeAll() {
            cache.removeAll()
            misses = 0
        }
    }
#endif
