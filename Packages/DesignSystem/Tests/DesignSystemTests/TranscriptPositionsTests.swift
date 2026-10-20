import ChatKit
import Testing
@testable import DesignSystem

@MainActor
struct TranscriptPositionsTests {
    @Test func accountsWithIdenticalConversationIDsNeverShareTheirPosition() throws {
        let positions = TranscriptPositions()
        let conversation = Conversation.ID("same")
        let first = try #require(positions.resume(account: "first", conversation: conversation))
        first.leave(.init(message: .init("older"), honoured: nil))
        #expect(positions.resume(account: "second", conversation: conversation)?.saved == nil)
        #expect(positions.resume(account: "first", conversation: conversation)?.saved?
            .message == .init("older"))
        #expect(positions.resume(account: "first", conversation: .init("other"))?.saved == nil)
        #expect(AccountScoped(account: "first", value: conversation) != AccountScoped(
            account: "second",
            value: conversation
        ))
    }
}
