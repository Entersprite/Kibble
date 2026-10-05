#if os(macOS)
    import AppKit
    import ChatKit

    /// A message's text with its mentions highlighted, for the AppKit text
    /// view (native text menu spec §2). `MentionHighlight.ranges` stays the one
    /// place that decides which spans count; this only spells its rules
    /// (ruling 6 of the mentions spec) in AppKit attributes, because the SwiftUI
    /// `AttributedString` carries SwiftUI fonts and colours AppKit cannot read.
    ///
    /// The accent is `controlAccentColor`: the app defines no accent of its
    /// own, so SwiftUI's `Color.accentColor` is the same system colour.
    enum MentionAttributes {
        static func attributed(
            _ text: String, mentions: [Mention], me: Member.ID?, inOwnBubble: Bool
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
                        .backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.25), range: span
                    )
                } else {
                    result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: span)
                }
            }
            return result
        }
    }
#endif
