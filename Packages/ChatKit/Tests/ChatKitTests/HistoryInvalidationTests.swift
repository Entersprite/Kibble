import Foundation
import Testing
@testable import ChatKit

/// History confidence can be withdrawn from the whole account or from listed
/// conversations, on one discriminator, so an older reader withdraws too much
/// rather than too little.
struct HistoryInvalidationTests {
    @Test func bothFormsHaveStableFrames() throws {
        try expectWireStable(ChatEvent.historyInvalidated, golden: "event-historyInvalidated")
        try expectWireStable(
            ChatEvent.conversationHistoryInvalidated([Conversation.ID("space/a"), Conversation.ID("dm/b")]),
            golden: "event-conversationHistoryInvalidated"
        )
    }

    @Test func aFrameWithoutTheListIsAccountWide() throws {
        let data = Data(#"{"type":"historyInvalidated"}"#.utf8)
        #expect(try JSONDecoder().decode(ChatEvent.self, from: data) == .historyInvalidated)
    }

    /// Unknown neighbours do not change which form it is.
    @Test func extraFieldsDoNotChangeTheScope() throws {
        let data = Data(#"{"type":"historyInvalidated","conversationIDs":["space/a"],"future":1}"#.utf8)
        #expect(
            try JSONDecoder().decode(ChatEvent.self, from: data)
                == .conversationHistoryInvalidated([Conversation.ID("space/a")])
        )
    }
}
