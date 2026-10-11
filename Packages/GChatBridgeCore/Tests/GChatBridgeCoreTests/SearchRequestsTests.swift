import Foundation
import Testing
@testable import GChatBridgeCore

/// `SBNmJb`'s inner payload, as captured (`findings.md` §65.2, §65.5, §65.6).
struct SearchRequestsTests {
    @Test func theFirstPageMatchesTheCapture() {
        let payload = SearchRequests.payload(MessageSearchPayload(text: "deploy", queryID: "Q"))
        #expect(payload == #"[null,null,null,"deploy",null,"Q",[[],null,null,null,"Q",null,0,"#
            + #"[[[[[[1]]]]],[[[1]]]]],null,[3],null,0,null,1]"#)
    }

    /// A later page carries the token at 1 and the clock at 7, and drops the
    /// query id from the filter (§65.2).
    @Test func aLaterPageCarriesTheToken() {
        let payload = SearchRequests.payload(MessageSearchPayload(
            text: "deploy", queryID: "Q", pageToken: "T", clientMillis: 1_790_000_000_000
        ))
        #expect(payload == #"[null,"T",null,"deploy",null,"Q",[[],null,null,null,null,null,0,"#
            + #"[[[[[[1]]]]],[[[1]]]]],1790000000000,[3],null,0,null,1]"#)
    }

    @Test func newestFirstIsTwo() {
        let payload = SearchRequests.payload(MessageSearchPayload(text: "x", queryID: "Q", newestFirst: true))
        #expect(payload.contains(",[2],"))
    }

    @Test func theUnexplainedSlotsCanBeSet() {
        let payload = SearchRequests.payload(MessageSearchPayload(
            text: "x", queryID: "Q", slot9: 113, slot11: "S", slot12: 2
        ))
        #expect(payload.hasSuffix(#",[3],[113],0,"S",2]"#))
    }

    @Test func aQueryIDIsThirtySixCharacters() {
        #expect(SearchRequests.newQueryID().count == 36)
        #expect(SearchRequests.newQueryID() != SearchRequests.newQueryID())
    }

    // MARK: - Filters (§65.5)

    /// With every new filter field left at its default, the payload is
    /// byte-identical to the one the probe already sends and depends on -
    /// `theFirstPageMatchesTheCapture` above pins the same string; this test
    /// states that guarantee explicitly, rather than leaving it implicit in
    /// every filter field happening to default to "unset".
    @Test func noFilterSetMatchesTheUnfilteredPayload() {
        let withoutFilters = SearchRequests.payload(MessageSearchPayload(text: "deploy", queryID: "Q"))
        let explicitlyUnset = SearchRequests.payload(MessageSearchPayload(
            text: "deploy", queryID: "Q", fromUserID: nil, olderThanMicros: nil, hasFile: false,
            hasLink: false, mentionsUserID: nil, conversationSpaceID: nil
        ))
        #expect(withoutFilters == explicitlyUnset)
        #expect(withoutFilters == #"[null,null,null,"deploy",null,"Q",[[],null,null,null,"Q",null,0,"#
            + #"[[[[[[1]]]]],[[[1]]]]],null,[3],null,0,null,1]"#)
    }

    @Test func fromSetsFilterIndexOne() {
        let payload = SearchRequests.payload(MessageSearchPayload(
            text: "x", queryID: "Q", fromUserID: "123456789012345678901"
        ))
        #expect(payload.contains(#",[["123456789012345678901"]],"#))
    }

    @Test func olderThanSetsFilterIndexTwoAsADecimalString() {
        let payload = SearchRequests.payload(MessageSearchPayload(
            text: "x", queryID: "Q", olderThanMicros: 1_700_000_123_456_789
        ))
        #expect(payload.contains(#",[null,"1700000123456789"],"#))
    }

    @Test func hasFileSetsFilterIndexThree() {
        let payload = SearchRequests.payload(MessageSearchPayload(text: "x", queryID: "Q", hasFile: true))
        #expect(payload.contains(",[[2]],"))
    }

    @Test func hasLinkSetsFilterIndexSixToOne() {
        let withoutLink = SearchRequests.payload(MessageSearchPayload(text: "x", queryID: "Q"))
        let withLink = SearchRequests.payload(MessageSearchPayload(text: "x", queryID: "Q", hasLink: true))
        #expect(withoutLink.contains("null,0,[[[[[[1]]]]]"))
        #expect(withLink.contains("null,1,[[[[[[1]]]]]"))
    }

    @Test func mentionsMeSetsFilterIndexFive() {
        let payload = SearchRequests.payload(MessageSearchPayload(
            text: "x", queryID: "Q", mentionsUserID: "123456789012345678901"
        ))
        #expect(payload.contains(#",[[[["123456789012345678901"]]]],"#))
    }

    /// Said in changes **two** indices together (§65.5: filter 0 and 7), to
    /// the exact shapes the capture isolated - the scope override replaces
    /// the default "conversations I'm in" entirely rather than adding to it.
    @Test func saidInSetsFilterIndicesZeroAndSeven() {
        let payload = SearchRequests.payload(MessageSearchPayload(
            text: "x", queryID: "Q", conversationSpaceID: "sp-1"
        ))
        #expect(payload.contains(#"[null,["space/sp-1","sp-1",2]],"#))
        #expect(payload.hasSuffix(#"[null,null,null,[[[["sp-1"]],1]]]],null,[3],null,0,null,1]"#))
    }
}
