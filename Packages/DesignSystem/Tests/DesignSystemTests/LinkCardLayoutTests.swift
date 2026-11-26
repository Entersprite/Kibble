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

    /// A titleless preview - a picker's GIF - names its host when it draws
    /// any text at all, never an empty title.
    @Test func anEmptyTitleFallsBackToTheHost() {
        let link = MessageLink(url: Self.url, preview: LinkPreview(title: "  "))
        #expect(LinkCardLayout.title(for: link) == "www.acme.example")
    }

    @Test func onlyATitlelessPreviewWithAPictureIsImageOnly() throws {
        let picture = try #require(URL(string: "https://media.acme.example/confetti.gif"))
        #expect(LinkCardLayout.isImageOnly(MessageLink(url: Self.url, preview: LinkPreview(
            title: "", imageURL: picture
        ))))
        #expect(!LinkCardLayout.isImageOnly(MessageLink(url: Self.url, preview: LinkPreview(
            title: "Specs", imageURL: picture
        ))))
        #expect(!LinkCardLayout.isImageOnly(MessageLink(url: Self.url, preview: LinkPreview(title: ""))))
        #expect(!LinkCardLayout.isImageOnly(MessageLink(url: Self.url)))
    }

    @Test func theDomainIsThePreviewsElseTheHostWithoutWWW() {
        let named = MessageLink(url: Self.url, preview: LinkPreview(title: "x", domain: "acme.example"))
        #expect(LinkCardLayout.domain(for: named) == "acme.example")
        let unnamed = MessageLink(url: Self.url, preview: LinkPreview(title: "x"))
        #expect(LinkCardLayout.domain(for: unnamed) == "acme.example")
    }

    /// Without a preview the title is already the host, so a second line
    /// would only repeat it (seen in the Task 13 render).
    @Test func aLinkWithoutAPreviewHasNoDomainLine() {
        #expect(LinkCardLayout.domain(for: MessageLink(url: Self.url)) == nil)
    }

    @Test func theImageKeepsItsAspectWithinBounds() {
        #expect(LinkCardLayout.imageHeight(width: 320, pixelWidth: 1200, pixelHeight: 630) == 168)
        #expect(LinkCardLayout.imageHeight(width: 320, pixelWidth: 100, pixelHeight: 1000) == 240)
        #expect(LinkCardLayout.imageHeight(width: 320, pixelWidth: 1000, pixelHeight: 10) == 80)
        #expect(LinkCardLayout.imageHeight(width: 320, pixelWidth: nil, pixelHeight: 630) == nil)
    }
}
