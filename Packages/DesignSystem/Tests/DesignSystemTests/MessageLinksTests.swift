import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct MessageLinksTests {
    private static let doc = URL(string: "https://acme.example/doc")!

    @Test func anAnchoredLinkKeepsItsSpanAndTarget() {
        let spans = MessageLinks.spans(
            in: "read the doc", links: [MessageLink(url: Self.doc, start: 9, length: 3)], avoiding: []
        )
        #expect(spans == [MessageLinks.Span(range: NSRange(location: 9, length: 3), url: Self.doc)])
    }

    @Test func aBareURLIsDetected() {
        let spans = MessageLinks.spans(in: "see https://acme.example/a now", links: [], avoiding: [])
        #expect(spans.map(\.range) == [NSRange(location: 4, length: 22)])
        #expect(spans.first?.url.absoluteString == "https://acme.example/a")
    }

    @Test func anAnnotationWinsOverTheDetectorOnTheSameText() {
        let text = "see https://acme.example/a now"
        let spans = MessageLinks.spans(
            in: text, links: [MessageLink(url: Self.doc, start: 4, length: 22)], avoiding: []
        )
        #expect(spans == [MessageLinks.Span(range: NSRange(location: 4, length: 22), url: Self.doc)])
    }

    @Test func aMentionIsNeverALink() {
        let spans = MessageLinks.spans(
            in: "@Alex read the doc", links: [MessageLink(url: Self.doc, start: 0, length: 5)],
            avoiding: [NSRange(location: 0, length: 5)]
        )
        #expect(spans.isEmpty)
    }

    /// Review Focus 2: UTF-16 past an emoji, and a span ending inside a
    /// surrogate pair.
    @Test func spansCountUTF16AndRefuseToSplitACharacter() {
        let text = "\u{1F44B}\u{1F3FD} the doc"
        let good = MessageLinks.spans(
            in: text, links: [MessageLink(url: Self.doc, start: 9, length: 3)], avoiding: []
        )
        #expect(good.map(\.range) == [NSRange(location: 9, length: 3)])
        let split = MessageLinks.spans(
            in: text, links: [MessageLink(url: Self.doc, start: 1, length: 3)], avoiding: []
        )
        #expect(split.isEmpty)
        // Starts on a boundary and ends inside the emoji: the end check alone
        // refuses it.
        let endSplit = MessageLinks.spans(
            in: "the \u{1F44B}\u{1F3FD}", links: [MessageLink(url: Self.doc, start: 4, length: 1)],
            avoiding: []
        )
        #expect(endSplit.isEmpty)
    }

    @Test func outOfRangeZeroAndUnanchoredSpansDrawNothing() {
        let links = [
            MessageLink(url: Self.doc, start: 9, length: 30),
            MessageLink(url: Self.doc, start: 2, length: 0),
            MessageLink(url: Self.doc)
        ]
        #expect(MessageLinks.spans(in: "read the doc", links: links, avoiding: []).isEmpty)
    }

    /// Review Focus 3.
    @Test func aRefusedSchemeGetsNoSpan() throws {
        let evil = try #require(URL(string: "javascript:alert(1)"))
        #expect(MessageLinks.spans(
            in: "click me", links: [MessageLink(url: evil, start: 0, length: 5)], avoiding: []
        ).isEmpty)
    }
}
