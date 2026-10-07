import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The demo world's links point at real text: every anchored span lies inside
/// its message, and Catalog holds each kind of link and a card (links spec §7.6).
struct FixtureLinksTests {
    @Test func everyAnchoredSpanIsInsideItsText() {
        for message in FixtureWorld.acme.messages {
            for link in message.links {
                guard let start = link.start, let length = link.length else { continue }
                #expect(start >= 0 && start + length <= message.text.utf16.count, "\(message.id)")
            }
        }
    }

    @Test func theCatalogHasAPreviewAHyperlinkAnUnanchoredPreviewAndACard() throws {
        let messages = FixtureWorld.acme.messages.filter { $0.conversationID == Acme.catalog }
        #expect(messages.contains { $0.links.contains { $0.start != nil && $0.preview != nil } })
        #expect(messages.contains { $0.links.contains { $0.start != nil && $0.preview == nil } })
        #expect(messages.contains { $0.links.contains { $0.start == nil && $0.preview != nil } })
        let card = try #require(messages.first { !$0.cards.isEmpty })
        #expect(card.sender == Acme.deployBot)
    }
}
