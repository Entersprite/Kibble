import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import InProcessChatTransport
import Testing

struct PolicyStoreTests {
    private struct RefusedStorage: ServiceStorageFactory {
        func open(_ account: ConnectedAccountID) throws -> any ServiceAccountStorage {
            throw ServiceFailure
                .internalFailure
        }

        func erase(_ account: ConnectedAccountID) {}
    }

    private func settings() -> NotificationSettings {
        var result = NotificationSettings()
        result.setRule(
            NotificationRule(sharesTyping: true, readReceipts: false),
            for: .global,
            at: Date(timeIntervalSince1970: 1_700_000_000),
            by: "device"
        )
        return result
    }

    @Test func removalAndAddingTheSameIdentityKeepsPolicyOutsideErasedAccountFiles() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        let first = try await harness.call(GetAccountPolicy(), account: record.id)
        let saved = try await harness.call(
            SetAccountPolicy(settings: settings(), expectedRevision: first.revision),
            account: record.id
        )
        _ = try await harness.call(RemoveAccount(), account: record.id)
        await harness.custody.configure(identity: record.selfID)
        let link = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("again")))
        _ = try await harness.call(CompleteAccountLink(linkID: link.id))
        #expect(link.accountID != record.id)
        let restored = try await harness.call(GetAccountPolicy(), account: link.accountID)
        #expect(restored == saved)
        let reopened = try SQLiteAccountRegistry(path: harness.directory
            .appendingPathComponent("registry.sqlite").path)
        let current = try #require(reopened.accounts().first)
        #expect(try reopened.policy(for: current) == saved)
        await harness.service.shutdown()
    }

    @Test func preferencesAreScopedByPrincipalAndVerifiedIdentity() throws {
        let registry = try SQLiteAccountRegistry(path: ":memory:")
        let first = LinkHarness.existing()
        _ = try registry.setPolicy(settings(), for: first, expectedRevision: "0")
        let foreignPrincipal = AccountRecord(
            id: ConnectedAccountID("other"),
            principalID: ServicePrincipalID("foreign"),
            selfID: first.selfID,
            label: "Other",
            credentialGeneration: "one"
        )
        let foreignIdentity = AccountRecord(
            id: ConnectedAccountID("other"),
            principalID: first.principalID,
            selfID: Member.ID("other"),
            label: "Other",
            credentialGeneration: "one"
        )
        #expect(try registry.policy(for: foreignPrincipal).revision == "0")
        #expect(try registry.policy(for: foreignIdentity).revision == "0")
        #expect(try registry.policy(for: first).settings == settings())
    }

    @Test func futureSchemasAndDuplicateScopesAreRefusedWithoutChangingPolicy() throws {
        let registry = try SQLiteAccountRegistry(path: ":memory:")
        let record = LinkHarness.existing()
        let before = try registry.setPolicy(settings(), for: record, expectedRevision: "0")
        var future = settings()
        future.schemaVersion += 1
        #expect(throws: ServiceFailure.unsupportedOperation) {
            try registry.setPolicy(future, for: record, expectedRevision: before.revision)
        }
        var duplicated = settings()
        duplicated.records += duplicated.records
        #expect(throws: ServiceFailure.invalidRequest) {
            try registry.setPolicy(duplicated, for: record, expectedRevision: before.revision)
        }
        #expect(try registry.policy(for: record) == before)
    }

    @Test func disabledPolicyAccessDoesNotOpenAccountStorageOrCreateAProvider() async throws {
        let registry = try SQLiteAccountRegistry(path: ":memory:")
        var record = LinkHarness.existing()
        record.isEnabled = false
        try registry.save(record)
        let providers = TestProviders()
        let service = ChatService(registry: registry, storage: RefusedStorage(), providers: providers)
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: record.principalID,
            deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("session"),
            accounts: [record.id]
        )
        let transport = InProcessChatTransport(endpoint: service, context: context)
        _ = try await transport.negotiate(.current)
        let request = try ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID("get"),
                accountID: record.id,
                accountRevision: record
                    .currentRevision
            ),
            payload: GetAccountPolicy()
        )
        let initial = try await transport.exchange(request).value(for: GetAccountPolicy.self)
        let update = try ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID("set"),
                accountID: record.id,
                accountRevision: record.currentRevision
            ),
            payload: SetAccountPolicy(settings: settings(), expectedRevision: initial.revision)
        )
        let policy = try await transport.exchange(update).value(for: SetAccountPolicy.self)
        #expect(policy.settings == settings())
        #expect(await providers.made.isEmpty)
        #expect(await service.activeRuntimeCount == 0)
        await service.shutdown()
    }
}
