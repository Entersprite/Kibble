import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The decisions behind a link card (links spec §7.3).
struct LinkCardLayoutTests {
    private static let url = URL(string: "https://www.acme.example/specs")!

    @Test func theTitleIsThePreviewsElseTheHost() {
        #expect(LinkCardLayout
            .title(for: MessageLink(url: Self.url, preview: LinkPreview(title: "Specs"))) == "Specs")
        #expect(LinkCardLayout.title(for: MessageLink(url: Self.url)) == "www.acme.example")
    }

    @Test func theDomainIsThePreviewsElseTheHostWithoutWWW() {
        let named = MessageLink(url: Self.url, preview: LinkPreview(title: "x", domain: "acme.example"))
        #expect(LinkCardLayout.domain(for: named) == "acme.example")
        #expect(LinkCardLayout.domain(for: MessageLink(url: Self.url)) == "acme.example")
    }

    @Test func theImageKeepsItsAspectWithinBounds() {
        #expect(LinkCardLayout.imageHeight(width: 320, pixelWidth: 1200, pixelHeight: 630) == 168)
        #expect(LinkCardLayout.imageHeight(width: 320, pixelWidth: 100, pixelHeight: 1000) == 240)
        #expect(LinkCardLayout.imageHeight(width: 320, pixelWidth: 1000, pixelHeight: 10) == 80)
        #expect(LinkCardLayout.imageHeight(width: 320, pixelWidth: nil, pixelHeight: 630) == nil)
    }
}
