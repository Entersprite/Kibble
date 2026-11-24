import ChatKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BlockedConversationsIntegrationTests {
    @Test func unblockingASharedAddressOnlyChangesTheBoundAccountsList() async throws {
        let harness = try await ClientHarness.make()
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()
        let draft = ConversationDraft(kind: .space, name: "Fixture Room")
        let firstRoom = try await first.createConversation(draft).conversation
        let secondRoom = try await second.createConversation(draft).conversation
        #expect(firstRoom.id == secondRoom.id)
        let command = ChatCommand.conversationAction(conversationID: firstRoom.id, action: .block)

        try await first.send(command)
        #expect(try await second.blockedConversations().isEmpty)
        #expect(try await second.unblockConversation(firstRoom.id).isEmpty)
        let expected = [BlockedConversation(id: firstRoom.id, name: draft.name)]
        #expect(try await first.blockedConversations() == expected)
        try await second.send(command)
        #expect(try await first.unblockConversation(firstRoom.id).isEmpty)
        #expect(try await first.blockedConversations().isEmpty)
        #expect(try await second.blockedConversations() == expected)
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }

    @Test func blockedPeopleAndUnblockFollowTheBoundAccount() async throws {
        let harness = try await ClientHarness.make()
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()
        let peer = Member.ID("peer")
        let firstDM = try await first.openDirectConversation(with: peer)
        let secondDM = try await second.openDirectConversation(with: peer)
        try await first.send(.conversationAction(conversationID: firstDM.id, action: .block))
        let expected = [BlockedPerson(id: peer, name: "Peer")]
        #expect(try await first.blockedPeople() == expected)
        #expect(try await first.blockedConversations().isEmpty)
        #expect(try await second.unblockPerson(peer).isEmpty)
        #expect(try await first.blockedPeople() == expected)
        try await second.send(.conversationAction(conversationID: secondDM.id, action: .block))
        #expect(try await first.unblockPerson(peer).isEmpty)
        #expect(try await first.blockedPeople().isEmpty)
        #expect(try await second.blockedPeople() == expected)
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }
}
