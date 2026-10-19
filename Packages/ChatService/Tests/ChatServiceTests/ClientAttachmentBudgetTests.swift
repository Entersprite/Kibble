import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct ClientAttachmentBudgetTests {
    @Test func oversizedHintsAndMissingReceiveTargetsPreserveCurrentInterest() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        let client = InterestTestClient(harness, device: "device", session: "client")
        let lease = try await client.attach()
        try await client.hint(.watchPresence(members: [Member.ID("current")]), lease: lease)
        await #expect(throws: ServiceFailure.overloaded) {
            try await client.hint(
                .watchPresence(members: (0 ..< 513).map { Member.ID("member-\($0)") }),
                lease: lease
            )
        }
        await #expect(throws: ServiceFailure.frameTooLarge) {
            try await client.hint(.watchPresence(members: (0 ..< 512).map {
                Member.ID(String(repeating: "x", count: 140) + String($0))
            }), lease: lease)
        }
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await client.hint(
                .watchPresence(members: [Member.ID(String(repeating: "x", count: 1025))]),
                lease: lease
            )
        }
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await client.hint(
                .watchConversationActivity(conversationID: Conversation.ID("unknown")),
                lease: lease
            )
        }
        try await authEventually { await harness.backend.receivePresence == [Member.ID("current")] }
        #expect(await harness.backend.receiveConversations.isEmpty)
        await harness.service.shutdown()
    }

    @Test func exhaustedInterestGenerationRetiresItsRuntimeWithoutErasingTheLogin() async throws {
        let harness = try await ReconciliationHarness.make()
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        await runtime.exhaustInterestGeneration()
        let client = InterestTestClient(harness, device: "device", session: "client")
        await #expect(throws: ServiceFailure.overloaded) { try await client.attach("2") }
        try await authEventually { await harness.service.activeRuntimeCount == 0 }
        let record = try #require(harness.registry.accounts().first)
        #expect(record.authenticationState == nil)
        #expect(record.credentialGeneration == harness.record.credentialGeneration)
        #expect(record.currentRevision == harness.record.currentRevision)
        await harness.service.shutdown()
    }

    @Test func liveClientBudgetRecoversAfterDetachAndGenerationFencesExpireWithoutGrowingForever(
    ) async throws {
        let harness = try await ReconciliationHarness.make()
        var clients: [(InterestTestClient, ClientAttachment)] = []
        for index in 0 ..< 63 {
            let client = InterestTestClient(harness, device: "device", session: "peer-\(index)")
            try await clients.append((client, client.attach()))
        }
        let extra = InterestTestClient(harness, device: "device", session: "extra")
        await #expect(throws: ServiceFailure.overloaded) { try await extra.attach() }
        try await clients[0].0.detach(clients[0].1)
        _ = try await extra.attach()
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        #expect(await runtime.clientInterests.values.count(where: { $0.lease != nil }) == 64)
        await runtime.expireClientInterests(at: .now + .seconds(121))
        #expect(await runtime.clientInterests.isEmpty)
        _ = try await extra.attach("2")
        #expect(await runtime.clientInterests.count == 1)
        await harness.service.shutdown()
    }

    @Test func churnCannotRetainAnUnboundedNumberOfRecentClientGenerations() async throws {
        let harness = try await ReconciliationHarness.make()
        for index in 0 ..< 255 {
            let client = InterestTestClient(harness, device: "device", session: "retired-\(index)")
            let lease = try await client.attach()
            try await client.detach(lease)
        }
        let extra = InterestTestClient(harness, device: "device", session: "extra")
        await #expect(throws: ServiceFailure.overloaded) { try await extra.attach() }
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        #expect(await runtime.clientInterests.count == 256)
        await runtime.expireClientInterests(at: .now + .seconds(121))
        _ = try await extra.attach()
        #expect(await runtime.clientInterests.count == 1)
        await harness.service.shutdown()
    }

    @Test(arguments: ["0", "01", "18446744073709551616"])
    func attachmentGenerationMustBeCanonicalAndPositive(_ generation: String) async throws {
        let harness = try await ReconciliationHarness.make()
        let client = InterestTestClient(harness, device: "device", session: "client")
        await #expect(throws: ServiceFailure.invalidRequest) { try await client.attach(generation) }
        #expect(try await client.attach().id == harness.attachment.id)
        await harness.service.shutdown()
    }
}

private extension AccountRuntime {
    func exhaustInterestGeneration() {
        interestRevision = .max
    }
}
