import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallMembershipAdmissionTests {
    @Test(arguments: [false, true])
    func unrelatedOrPartialMembershipUpdatesDoNotInvalidateAFreshDirectCheck(partial: Bool) async throws {
        let harness = try await CallHarness.make(heldMembership: true)
        let account = harness.accounts[0]
        let recipient = try #require(try await harness.read(account).recipients.first)
        let gate = try #require(await harness.providers.gate(account.id))
        let runtime = try #require(await harness.service.runtimes[account.id])
        let command = Task {
            try await harness.client().call(
                ControlCall(
                    action: "start",
                    callID: UUID(),
                    recipient: recipient,
                    sourceID: harness.read(account).sourceID
                ),
                account: account.id,
                revision: account.currentRevision
            )
        }
        do {
            try await callEventually { await gate.held }
            let update: ChatEvent = partial
                ? .conversationUpdated(.init(
                    id: recipient.conversationID,
                    kind: .directMessage,
                    title: "Changed title"
                ))
                : .conversationUpdated(.init(id: .init("other"), kind: .space, members: [account.selfID]))
            try await runtime.appendAndPublish(update, live: true)
            await gate.release()
            #expect(try await command.value.call != nil)
            await harness.service.shutdown()
        } catch {
            await gate.release()
            _ = await command.result
            await harness.service.shutdown()
            throw error
        }
    }
}
