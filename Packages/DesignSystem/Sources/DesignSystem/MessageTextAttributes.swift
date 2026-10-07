#if os(macOS)
    import AppKit
    import ChatKit

    /// A message's text with its mentions highlighted and its links set, for
    /// the AppKit text view (native text menu spec §2; links spec §7.2).
    /// `MentionHighlight.ranges` and `MessageLinks.spans` stay the places that
    /// decide which spans count; this only spells their rules
    /// (ruling 6 of the mentions spec) in AppKit attributes, because the SwiftUI
    /// `AttributedString` carries SwiftUI fonts and colours AppKit cannot read.
    ///
    /// The accent is `controlAccentColor`: the app defines no accent of its
    /// own, so SwiftUI's `Color.accentColor` is the same system colour.
    enum MessageTextAttributes {
        static func attributed(
            _ text: String, mentions: [Mention], links: [MessageLink], me: Member.ID?, inOwnBubble: Bool
        ) -> NSAttributedString {
            let base = NSFont.preferredFont(forTextStyle: .body)
            let result = NSMutableAttributedString(string: text, attributes: [
                .font: base,
                .foregroundColor: inOwnBubble ? NSColor.white : NSColor.labelColor
            ])
            let semibold = NSFont.systemFont(ofSize: base.pointSize, weight: .semibold)
            for (range, isMe) in MentionHighlight.ranges(in: text, mentions: mentions, me: me) {
                let span = NSRange(range, in: text)
                result.addAttribute(.font, value: semibold, range: span)
                guard !inOwnBubble else { continue }
                if isMe {
                    result.addAttribute(
                        .backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.25),
                        range: span
                    )
                } else {
                    result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: span)
                }
            }
            let mentionRanges = MentionHighlight.ranges(in: text, mentions: mentions, me: me)
                .map { NSRange($0.range, in: text) }
            for span in MessageLinks.spans(in: text, links: links, avoiding: mentionRanges) {
                result.addAttribute(.link, value: span.url, range: span.range)
                result.addAttribute(.toolTip, value: span.url.absoluteString, range: span.range)
            }
            return result
        }

        /// How the text view draws links. `NSTextView` applies these over a
        /// run's own foreground colour, so the bubble's colour is set here:
        /// accent in others' bubbles, white in your own (accent on accent
        /// would vanish).
        static func linkAttributes(inOwnBubble: Bool) -> [NSAttributedString.Key: Any] {
            [
                .foregroundColor: inOwnBubble ? NSColor.white : NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand
            ]
        }
    }
#endif
