import Foundation
import Testing
@testable import ChatKit

/// The search seam on the wire (search spec §2).
struct MessageSearchTests {
    static let full = MessageSearchQuery(
        text: "deploy", from: Fixture.humanID, conversation: Fixture.spaceID,
        olderThan: Fixture.readAt, newerThan: Fixture.createdAt,
        hasFile: true, hasLink: true, mentionsMe: true, order: .newest
    )

    @Test func aFullQueryMatchesItsGolden() throws {
        try expectWireStable(Self.full, golden: "search-query")
    }

    /// An older client asks for less, never for something it did not mean.
    @Test func anEmptyObjectIsAPlainQuery() throws {
        #expect(try Wire.decode(MessageSearchQuery.self, from: "{}") == MessageSearchQuery())
    }

    @Test func aPageMatchesItsGolden() throws {
        try expectWireStable(
            MessageSearchPage(hits: [Fixture.message, Fixture.reply], next: MessageSearchCursor("page-2")),
            golden: "search-page"
        )
    }

    @Test func theLastPageHasNoCursor() throws {
        #expect(try !Wire.json(MessageSearchPage()).contains("next"))
    }

    @Test func anUnknownOrderRoundTrips() throws {
        let decoded = try Wire.decode(MessageSearchOrder.self, from: #""bySender""#)
        #expect(decoded == .unknown("bySender"))
        #expect(try Wire.json(decoded) == #""bySender""#)
    }

    @Test func anUnknownFilterRoundTrips() throws {
        let decoded = try Wire.decode(MessageSearchFilter.self, from: #""hasPoll""#)
        #expect(decoded == .unknown("hasPoll"))
        #expect(try Wire.json(decoded) == #""hasPoll""#)
    }

    @Test func textAndOrderAreNotFilters() {
        #expect(!MessageSearchQuery(text: "x", order: .newest).hasFilters)
        #expect(MessageSearchQuery(hasLink: true).hasFilters)
        #expect(MessageSearchQuery(olderThan: Fixture.readAt).hasFilters)
    }
}
