import ChatKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// An app card's text for SwiftUI (links spec §7.4).
struct RichTextAttributesTests {
    @Test func stylesBecomeInlineIntentsAndUnderline() {
        let text = RichTextAttributes.attributed(RichText(runs: [
            RichText.Run(text: "bold", bold: true),
            RichText.Run(text: "both", bold: true, italic: true),
            RichText.Run(text: "gone", strikethrough: true),
            RichText.Run(text: "under", underline: true)
        ]))
        let runs = Array(text.runs)
        #expect(runs[0].inlinePresentationIntent == .stronglyEmphasized)
        #expect(runs[1].inlinePresentationIntent == [.stronglyEmphasized, .emphasized])
        #expect(runs[2].inlinePresentationIntent == .strikethrough)
        #expect(runs[3].underlineStyle == .single)
        #expect(String(text.characters) == "boldbothgoneunder")
    }

    /// Review Focus 3: a refused scheme is text, not a link.
    @Test func onlyAllowedLinksAreLinks() {
        let text = RichTextAttributes.attributed(RichText(runs: [
            RichText.Run(text: "ok", link: URL(string: "https://acme.example")),
            RichText.Run(text: "no", link: URL(string: "javascript:alert(1)"))
        ]))
        let runs = Array(text.runs)
        #expect(runs[0].link == URL(string: "https://acme.example"))
        #expect(runs[1].link == nil)
    }
}
