import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Google's formatted text to `RichText` (links spec §4.3).
struct RichTextMappingTests {
    private typealias Element = JAddOnsFormattedText.FormattedTextElement

    private func styled(
        _ text: String,
        styles: [Element.StyledText.Style] = [],
        bold: Bool = false
    ) -> Element {
        var element = Element()
        element.styledText.text = text
        element.styledText.styles = styles
        if bold {
            element.styledText.fontWeight = .bold
        }
        return element
    }

    private func formatted(_ elements: [Element]) -> JAddOnsFormattedText {
        var text = JAddOnsFormattedText()
        text.formattedTextElements = elements
        return text
    }

    @Test func stylesBecomeFlags() {
        let mapped = RichTextMapping.text(formatted([
            styled("When ", bold: true), styled("it ships", styles: [.italic, .underline]),
            styled("old", styles: [.strikethrough]), styled("loud", styles: [.uppercase])
        ]))
        #expect(mapped?.runs == [
            RichText.Run(text: "When ", bold: true),
            RichText.Run(text: "it ships", italic: true, underline: true),
            RichText.Run(text: "old", strikethrough: true),
            RichText.Run(text: "LOUD")
        ])
    }

    @Test func aDeprecatedBoldStyleIsBoldAndABreakIsANewline() {
        let mapped = RichTextMapping.text(formatted([
            styled("a", styles: [.boldDeprecated]), styled("b", styles: [.br])
        ]))
        #expect(mapped?.plainText == "a\nb")
        #expect(mapped?.runs.first?.bold == true)
    }

    /// Review Focus 3.
    @Test func aHyperlinkKeepsOnlyAWebOrMailTarget() {
        var good = Element()
        good.hyperlink.link = "https://acme.example/pr"
        good.hyperlink.text = "the PR"
        var evil = Element()
        evil.hyperlink.link = "javascript:alert(1)"
        evil.hyperlink.text = "click"
        let mapped = RichTextMapping.text(formatted([good, evil]))
        #expect(mapped?.runs == [
            RichText.Run(text: "the PR", link: URL(string: "https://acme.example/pr")),
            RichText.Run(text: "click")
        ])
    }

    @Test func originalTextIsStrippedOfMarkup() {
        var text = JAddOnsFormattedText()
        text.originalText = "<b>Shipped</b> to <i>prod</i><br>Logs &amp; traces"
        #expect(RichTextMapping.text(text)?.plainText == "Shipped to prod\nLogs & traces")
    }

    @Test func emptyTextIsNil() {
        #expect(RichTextMapping.text(JAddOnsFormattedText()) == nil)
        #expect(RichTextMapping.text(formatted([styled("")])) == nil)
    }
}
