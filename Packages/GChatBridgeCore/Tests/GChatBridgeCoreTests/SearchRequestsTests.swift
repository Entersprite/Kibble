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
}
