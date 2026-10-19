import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct InterestCoordinationTests {
    @Test func detachingOneClientKeepsTheOtherClientsReceiveAndActivityInterests() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        let firstClient = InterestTestClient(harness, device: "device", session: "client")
        let secondClient = InterestTestClient(harness, device: "other", session: "client")
        let first = try await firstClient.attach(), second = try await secondClient.attach()
        let one = Conversation.ID("one"), two = Conversation.ID("two")
        try await harness.addConversation(one)
        try await harness.addConversation(two)
        let firstPerson = Member.ID("first"), secondPerson = Member.ID("second")
        try await firstClient.hint(.watchPresence(members: [firstPerson]), lease: first)
        try await secondClient.hint(.watchPresence(members: [secondPerson]), lease: second)
        try await firstClient.hint(.watchConversationActivity(conversationID: one), lease: first)
        try await secondClient.hint(.watchConversationActivity(conversationID: two), lease: second)
        try await firstClient.hint(.reportActivity(active: false), lease: first)
        try await secondClient.hint(.reportActivity(active: true), lease: second)
        try await authEventually {
            let presence = await harness.backend.receivePresence
            let conversations = await harness.backend.receiveConversations
            return presence == [firstPerson, secondPerson] && conversations == [one, two]
        }
        try await firstClient.detach(first)
        try await authEventually {
            let presence = await harness.backend.receivePresence
            let conversations = await harness.backend.receiveConversations
            return presence == [secondPerson] && conversations == [two]
        }
        #expect(await harness.backend.sentCommands.last == .reportActivity(active: true))
        #expect(await harness.service.activeRuntimeCount == 1)
        try await secondClient.detach(second)
        try await authEventually {
            let presence = await harness.backend.receivePresence
            let conversations = await harness.backend.receiveConversations
            let last = await harness.backend.sentCommands.last
            return presence.isEmpty && conversations.isEmpty && last == .reportActivity(active: false)
        }
        await harness.service.shutdown()
    }

    @Test func staleLeasesAndOlderAttachmentGenerationsCannotReplaceANewerClient() async throws {
        let harness = try await ReconciliationHarness.make()
        let client = InterestTestClient(harness, device: "device", session: "client")
        let old = try await client.attach()
        let current = try await client.attach("2")
        #expect(old.id != current.id)
        await #expect(throws: ServiceFailure.clientAttachmentExpired) { try await client.attach("1") }
        await #expect(throws: ServiceFailure.clientAttachmentExpired) {
            try await client.hint(.reportActivity(active: true), lease: old)
        }
        try await client.detach(old)
        try await client.hint(.reportActivity(active: true), lease: current)
        #expect(try await client.attach("2").id == current.id)
        let foreign = InterestTestClient(harness, device: "foreign", session: "client")
        await #expect(throws: ServiceFailure.clientAttachmentExpired) {
            try await foreign.hint(.reportActivity(active: false), lease: current)
        }
        try await client.detach(current)
        await #expect(throws: ServiceFailure.clientAttachmentExpired) { try await client.attach("2") }
        let newer = try await client.attach("3")
        #expect(newer.id != current.id)
        await harness.service.shutdown()
    }

    @Test func lateHintsCannotUndoNewerIntentAndSequenceReuseCannotChangePayload() async throws {
        let harness = try await ReconciliationHarness.make()
        let client = InterestTestClient(harness, device: "device", session: "client")
        let lease = try await client.attach()
        try await harness.addConversation(Conversation.ID("separate-field"))
        try await client.hint(.reportActivity(active: false), lease: lease, sequence: "20")
        try await client.hint(.reportActivity(active: true), lease: lease, sequence: "19")
        await #expect(throws: ServiceFailure.operationConflict) {
            try await client.hint(.reportActivity(active: true), lease: lease, sequence: "20")
        }
        try await client.hint(.watchPresence(members: [Member.ID("current")]), lease: lease, sequence: "100")
        try await client.hint(.watchPresence(members: [Member.ID("old")]), lease: lease, sequence: "1")
        try await client.hint(
            .watchConversationActivity(conversationID: Conversation.ID("separate-field")),
            lease: lease,
            sequence: "1"
        )
        try await authEventually {
            let presence = await harness.backend.receivePresence
            let conversations = await harness.backend.receiveConversations
            return presence == [Member.ID("current")] && conversations == [Conversation.ID("separate-field")]
        }
        #expect(await !harness.backend.sentCommands.contains(.reportActivity(active: true)))
        await harness.service.shutdown()
    }

    @Test func expiredLostClientsWithdrawOnlyTheirOwnInterestsAndCannotRenewTheRetiredGeneration(
    ) async throws {
        let harness = try await ReconciliationHarness.make()
        let client = InterestTestClient(harness, device: "device", session: "client")
        let lease = try await client.attach()
        try await client.hint(.reportActivity(active: true), lease: lease)
        try await authEventually { await harness.backend.sentCommands.last == .reportActivity(active: true) }
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        await runtime.expireClientInterests(at: .now + .seconds(61))
        try await authEventually { await harness.backend.sentCommands.last == .reportActivity(active: false) }
        await #expect(throws: ServiceFailure.clientAttachmentExpired) { try await client.attach() }
        await #expect(throws: ServiceFailure.clientAttachmentExpired) {
            try await client.hint(.reportActivity(active: true), lease: lease)
        }
        #expect(await harness.service.activeRuntimeCount == 1)
        _ = try await client.attach("2")
        await harness.service.shutdown()
    }
}
