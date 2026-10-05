#if os(macOS)
    import AppKit
    import ChatKit
    import Testing
    @testable import DesignSystem

    /// `MentionAttributes`: `MentionHighlight`'s rules, for AppKit. The spans
    /// come from `MentionHighlight.ranges`; only the attributes are new.
    @MainActor
    struct MentionAttributesTests {
        private let me = Member.ID("me")
        private let text = "@Me and @Ann hi"
        private var mentions: [Mention] {
            [
                Mention(target: .user(me), start: 0, length: 3),
                Mention(target: .user(Member.ID("ann")), start: 8, length: 4)
            ]
        }

        private static let base = NSFont.preferredFont(forTextStyle: .body)

        private func attribute(
            _ key: NSAttributedString.Key, at index: Int, inOwnBubble: Bool = false
        ) -> Any? {
            MentionAttributes.attributed(text, mentions: mentions, me: me, inOwnBubble: inOwnBubble)
                .attribute(key, at: index, effectiveRange: nil)
        }

        private func weight(at index: Int, inOwnBubble: Bool = false) -> CGFloat? {
            let font = attribute(.font, at: index, inOwnBubble: inOwnBubble) as? NSFont
            let traits = font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return traits?[.weight] as? CGFloat
        }

        @Test func plainTextIsTheBodyFontInTheLabelColour() {
            #expect((attribute(.font, at: 5) as? NSFont)?.pointSize == Self.base.pointSize)
            #expect(attribute(.foregroundColor, at: 5) as? NSColor == .labelColor)
            #expect(attribute(.backgroundColor, at: 5) == nil)
        }

        @Test func inYourOwnBubbleTheTextIsWhite() {
            #expect(attribute(.foregroundColor, at: 5, inOwnBubble: true) as? NSColor == .white)
        }

        @Test func aMentionOfYouIsSemiboldOnAnAccentBackground() throws {
            let semibold = try #require(weight(at: 0))
            #expect(semibold > (weight(at: 5) ?? 0))
            let background = try #require(attribute(.backgroundColor, at: 0) as? NSColor)
            #expect(background == NSColor.controlAccentColor.withAlphaComponent(0.25))
        }

        @Test func someoneElsesMentionIsSemiboldInTheAccent() throws {
            #expect(try #require(weight(at: 9)) > (weight(at: 5) ?? 0))
            #expect(attribute(.foregroundColor, at: 9) as? NSColor == .controlAccentColor)
            #expect(attribute(.backgroundColor, at: 9) == nil)
        }

        /// Ruling 6 of the mentions spec: accent on accent is unreadable.
        @Test func inYourOwnBubbleAMentionIsOnlySemibold() throws {
            #expect(try #require(weight(at: 0, inOwnBubble: true)) > (weight(at: 5, inOwnBubble: true) ?? 0))
            #expect(attribute(.backgroundColor, at: 0, inOwnBubble: true) == nil)
            #expect(attribute(.foregroundColor, at: 9, inOwnBubble: true) as? NSColor == .white)
        }

        /// A span `MentionHighlight` drops (not starting with `@`) gets nothing.
        @Test func aDroppedSpanStaysPlain() {
            let plain = MentionAttributes.attributed(
                "hello", mentions: [Mention(target: .user(me), start: 0, length: 3)], me: me,
                inOwnBubble: false
            )
            #expect(plain.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
            #expect((plain.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) == Self.base)
        }
    }
#endif
