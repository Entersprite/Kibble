import ChatAPI
import ChatKit
import ChatService
import Foundation
import Testing

struct LinkRemovalTests {
    @Test func anUnverifiedAddCannotResurrectARemovedIdentityAfterRestart() async throws {
        let record = LinkHarness.existing()
        let initial = try await LinkHarness.make(records: [record])
        let begun = try await initial.call(BeginAccountLink(operationID: ServiceOperationID("before")))
        _ = try await initial.call(RemoveAccount(), account: record.id)
        let harness = try await initial.restarted()
        await harness.custody.configure(identity: record.selfID)
        await #expect(throws: ServiceFailure.staleAccount) {
            try await harness.call(CompleteAccountLink(linkID: begun.id))
        }
        #expect(try harness.registry.accounts().isEmpty)
        #expect(try harness.registry.links().first?.phase == "canceled")
        #expect(await harness.custody.installs == 0)
        #expect(await harness.custody.discarded == [begun.id])
        let fresh = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("after")))
        let completed = try await harness.call(CompleteAccountLink(linkID: fresh.id))
        #expect(completed.phase == "completed")
        #expect(completed.accountID != record.id)
        #expect(try harness.registry.accounts().map(\.selfID) == [record.selfID])
        await harness.service.shutdown()
    }

    @Test func removingOneIdentityDoesNotInvalidateAnotherPendingAdd() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        let begun = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("other")))
        _ = try await harness.call(RemoveAccount(), account: record.id)
        let completed = try await harness.call(CompleteAccountLink(linkID: begun.id))
        #expect(completed.phase == "completed")
        #expect(try harness.registry.accounts().map(\.selfID) == [Member.ID("new-self")])
        await harness.service.shutdown()
    }

    @Test func accountRemovalCleansAnInterruptedReconnectInstallation() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        await harness.custody.configure(identity: record.selfID, failAfterInstall: true)
        let begun = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("reconnect"), targetAccountID: record.id
        ))
        await #expect(throws: ServiceFailure.internalFailure) {
            try await harness.call(CompleteAccountLink(linkID: begun.id))
        }
        let link = try #require(harness.registry.links().first)
        #expect(link.phase == "installing")
        #expect(await harness.custody.installed == [link.generation])
        _ = try await harness.call(RemoveAccount(), account: record.id)
        #expect(await harness.custody.erased == [link.generation])
        #expect(await harness.custody.discarded == [link.id])
        #expect(await harness.providers.forgotten == [record.id])
        #expect(try harness.registry.accounts().isEmpty)
        #expect(try harness.registry.links().first?.phase == "canceled")
        await harness.service.shutdown()
    }

    @Test func refusedLinkCleanupKeepsRemovalRetryableWithoutAdvancingRetirementAgain() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        let begun = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("reconnect"), targetAccountID: record.id
        ))
        await harness.custody.configure(discardFailures: 1)
        await #expect(throws: ServiceFailure.internalFailure) {
            try await harness.call(RemoveAccount(), account: record.id)
        }
        #expect(try harness.registry.accounts().first?.isRemoving == true)
        #expect(await harness.providers.forgotten.isEmpty)
        #expect(try harness.registry.removalRevision() == "1")
        _ = try await harness.call(RemoveAccount(), account: record.id)
        #expect(try harness.registry.accounts().isEmpty)
        #expect(try harness.registry.removalRevision() == "1")
        #expect(await harness.providers.forgotten == [record.id])
        #expect(await harness.custody.discarded == [begun.id])
        await harness.service.shutdown()
    }

    @Test func registryCommitRechecksRetirementInTheBindingTransaction() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        let begun = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("before")))
        var link = try #require(harness.registry.links().first)
        link.selfID = record.selfID
        link.phase = "installing"
        try harness.registry.saveLink(link)
        _ = try await harness.call(RemoveAccount(), account: record.id)
        let replacement = AccountRecord(
            id: begun.accountID, principalID: record.principalID, selfID: record.selfID,
            label: "Replacement", credentialGeneration: link.generation
        )
        #expect(throws: ServiceFailure.staleAccount) {
            try harness.registry.commitLink(link, account: replacement)
        }
        #expect(try harness.registry.accounts().isEmpty)
        #expect(try harness.registry.links().first?.phase == "installing")
        await harness.service.shutdown()
    }
}
