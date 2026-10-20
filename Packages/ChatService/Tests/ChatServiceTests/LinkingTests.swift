import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

struct LinkingTests {
    @Test func addIsIdempotentAndNewAccountAppearsThroughTheSerializedOwnerContext() async throws {
        let harness = try await LinkHarness.make()
        let request = BeginAccountLink(operationID: ServiceOperationID("add"))
        let begun = try await harness.call(request)
        #expect(try await harness.call(request) == begun)
        let intent = try await harness.service.captureIntent(begun.id, context: harness.context)
        #expect(intent.phase == "pendingCapture")
        #expect(try await harness.call(ListAccounts()).isEmpty)
        let completed = try await harness.call(CompleteAccountLink(linkID: begun.id))
        #expect(completed.phase == "completed")
        #expect(try await harness.call(CompleteAccountLink(linkID: begun.id)) == completed)
        let accounts = try await harness.call(ListAccounts())
        #expect(accounts.map(\.id) == [begun.accountID])
        #expect(accounts.first?.selfID == Member.ID("new-self"))
        #expect(await harness.custody.installs == 1)
        #expect(await harness.custody.discarded == [begun.id])
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.service.shutdown()
    }

    @Test func reconnectRejectsAnotherIdentityAndPreservesTheExistingProvider() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        let begun = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("reauth"),
            targetAccountID: record.id
        ))
        await #expect(throws: ServiceFailure.wrongIdentity) {
            try await harness.call(CompleteAccountLink(linkID: begun.id))
        }
        let retained = try harness.registry.accounts()
        #expect(retained.count == 1)
        var original = try #require(retained.first)
        // Profile hydration and ordering may advance independently; the
        // identity, credential binding and lifecycle must remain untouched.
        original.profile = record.profile
        original.position = record.position
        #expect(original == record)
        #expect(await harness.service.activeRuntimeCount == 1)
        #expect(await harness.custody.installs == 0)
        let canceled = try await harness.call(CancelAccountLink(linkID: begun.id))
        #expect(canceled.phase == "canceled")
        #expect(try await harness.custody
            .erased == [#require(harness.registry.links().first?.generation)])
        await harness.service.shutdown()
    }

    @Test func reconnectPreservesDisableIntentAndCleansOnlyThePreviousGeneration() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        await harness.custody.configure(identity: record.selfID)
        let begun = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("reauth"),
            targetAccountID: record.id
        ))
        _ = try await harness.call(SetAccountEnabled(enabled: false), account: record.id)
        let done = try await harness.call(CompleteAccountLink(linkID: begun.id))
        #expect(done.phase == "completed")
        let saved = try #require(harness.registry.accounts().first)
        #expect(saved.id == record.id)
        #expect(!saved.isEnabled)
        #expect(saved.credentialGeneration != record.credentialGeneration)
        #expect(await harness.service.activeRuntimeCount == 0)
        #expect(await harness.custody.erased == [record.credentialGeneration])
        #expect(await harness.custody.installs == 1)
        await harness.service.shutdown()
    }

    @Test func aSecondAddOfTheSameIdentityCannotReplaceTheFirstAccount() async throws {
        let harness = try await LinkHarness.make()
        let first = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("one")))
        _ = try await harness.call(CompleteAccountLink(linkID: first.id))
        let second = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("two")))
        let duplicate = try await harness.call(CompleteAccountLink(linkID: second.id))
        #expect(duplicate.phase == "alreadyConnected")
        #expect(duplicate.accountID == first.accountID)
        #expect(try harness.registry.accounts().map(\.id) == [first.accountID])
        #expect(await harness.custody.installs == 1)
        _ = try await harness.call(CancelAccountLink(linkID: second.id))
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.service.shutdown()
    }

    @Test func aLostInstallResponseRecoversOnRestartWithoutInstallingTwice() async throws {
        let custody = TestLinkCustody()
        await custody.configure(failAfterInstall: true)
        let harness = try await LinkHarness.make(custody: custody)
        let begun = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("one")))
        await #expect(throws: ServiceFailure.internalFailure) {
            try await harness.call(CompleteAccountLink(linkID: begun.id))
        }
        #expect(try harness.registry.accounts().isEmpty)
        #expect(try harness.registry.links().first?.phase == "installing")
        await harness.service.shutdown()
        let service = ChatService(
            registry: harness.registry,
            storage: SQLiteServiceStorageFactory(directory: harness.directory),
            providers: TestProviders(),
            linkCustody: custody
        )
        try await service.restore()
        for _ in 0 ..< 1000 {
            if try harness.registry.links().first?.phase == "completed" {
                break
            }
            await Task.yield()
        }
        #expect(try harness.registry.links().first?.phase == "completed")
        #expect(try harness.registry.accounts().map(\.id) == [begun.accountID])
        #expect(await custody.installs == 1)
        #expect(await service.activeRuntimeCount == 1)
        await service.shutdown()
    }

    @Test func cancelInterruptsVerificationAndDoesNotCreateAnAccount() async throws {
        let custody = TestLinkCustody()
        await custody.configure(holdVerification: true)
        let harness = try await LinkHarness.make(custody: custody)
        let begun = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("one")))
        let completion = Task { try await harness.call(CompleteAccountLink(linkID: begun.id)) }
        for _ in 0 ..< 1000 {
            if await custody.verifying {
                break
            }
            await Task.yield()
        }
        #expect(await custody.verifying)
        let canceled = try await harness.call(CancelAccountLink(linkID: begun.id))
        _ = await completion.result
        #expect(canceled.phase == "canceled")
        #expect(try harness.registry.accounts().isEmpty)
        #expect(await custody.installs == 0)
        #expect(await custody.discarded == [begun.id])
        await harness.service.shutdown()
    }

    @Test func accountRemovalDuringPendingReconnectCannotBeUndoneByCompletion() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        await harness.custody.configure(identity: record.selfID)
        let begun = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("reauth"),
            targetAccountID: record.id
        ))
        _ = try await harness.call(RemoveAccount(), account: record.id)
        let completed = try await harness.call(CompleteAccountLink(linkID: begun.id))
        #expect(completed.phase == "canceled")
        #expect(try harness.registry.accounts().isEmpty)
        #expect(await harness.custody.installs == 0)
        _ = try await harness.call(CancelAccountLink(linkID: begun.id))
        await harness.service.shutdown()
    }
}
