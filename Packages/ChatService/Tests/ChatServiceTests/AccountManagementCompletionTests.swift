import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AccountManagementCompletionTests {
    @Test func explicitSignOutKeepsIdentityProfileOrderAndPolicyAndIsIdempotent() async throws {
        var record = LinkHarness.existing()
        record.position = 7
        record.profile = .init(displayName: "Alex", email: "alex@example.invalid", organization: .personal)
        let harness = try await LinkHarness.make(records: [record])
        let prior = try await harness.call(GetAccountPolicy(), account: record.id)
        let signedOut = try await harness.call(SignOutAccount(), account: record.id)
        #expect(signedOut.authenticationState == "required")
        let stored = try #require(harness.registry.accounts().first)
        #expect(stored.selfID == record.selfID && stored.profile == record.profile && stored.position == 7)
        #expect(try harness.registry.policy(for: stored) == prior)
        #expect(try await harness.call(SignOutAccount(), account: record.id)
            .authenticationState == "required")
        #expect(await harness.providers.forgotten.contains(record.id))
        await harness.service.shutdown()
    }

    @Test func failedSignOutCleanupIsExplicitlyPendingAndCanBeRetried() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        await harness.providers.failNextForget()
        await #expect(throws: ServiceFailure.accountCleanupPending) {
            try await harness.call(SignOutAccount(), account: record.id)
        }
        #expect(try harness.registry.accounts().first?.authenticationState == "erasing")
        #expect(try await harness.call(SignOutAccount(), account: record.id)
            .authenticationState == "required")
        await harness.service.shutdown()
    }

    @Test func reorderingRejectsDuplicatesAndForeignAccountsWithoutChangingOrder() async throws {
        let first = LinkHarness.existing()
        let second = AccountRecord(
            id: .init("other"),
            principalID: first.principalID,
            selfID: .init("other-self"),
            label: "Other",
            isEnabled: false,
            credentialGeneration: "two"
        )
        let harness = try await LinkHarness.make(records: [first, second])
        let arranged = try await harness.call(ReorderAccounts(accounts: [second.id, first.id]))
        #expect(arranged.map(\.id) == [second.id, first.id])
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await harness.call(ReorderAccounts(accounts: [first.id, first.id]))
        }
        await #expect(throws: ServiceFailure.accountNotFound) {
            try await harness.call(ReorderAccounts(accounts: [.init("foreign")]))
        }
        #expect(try await harness.call(ListAccounts()).map(\.id) == [second.id, first.id])
        let restarted = try await harness.restarted()
        #expect(try await restarted.call(ListAccounts()).map(\.id) == [second.id, first.id])
        await restarted.service.shutdown()
    }

    @Test func forgettingRemovalResumesItsOriginalChoiceAfterInterruption() async throws {
        var record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        var settings = NotificationSettings()
        settings.setRule(.init(readReceipts: false), for: .global, at: Date(), by: "test")
        _ = try harness.registry.setPolicy(settings, for: record, expectedRevision: "0")
        await harness.service.shutdown()
        record.isRemoving = true; record.isEnabled = false; record.forgetsSettings = true
        try harness.registry.save(record)
        let restored = try await harness.restarted()
        for _ in 0 ..< 1000 {
            if try restored.registry.accounts().isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(try restored.registry.accounts().isEmpty)
        #expect(try restored.registry.policy(for: record).revision == "0")
        await restored.service.shutdown()
    }

    @Test func targetedReconnectRefusesAnotherIdentityBeforeInstallingIt() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        _ = try await harness.call(SignOutAccount(), account: record.id)
        await harness.custody.configure(identity: .init("different"))
        let link = try await harness.call(BeginAccountLink(
            operationID: .init("wrong-account"),
            targetAccountID: record.id
        ))
        await #expect(throws: ServiceFailure.wrongIdentity) {
            try await harness.call(CompleteAccountLink(linkID: link.id))
        }
        #expect(await harness.custody.installs == 0)
        #expect(try harness.registry.accounts().first?.selfID == record.selfID)
        _ = try await harness.call(CancelAccountLink(linkID: link.id))
        await harness.service.shutdown()
    }
}
