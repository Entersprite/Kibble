import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import InProcessChatTransport
import Testing

struct LifecycleTests {
    @Test func twoAccountsAndTwoClientsRemainIndependent() async throws {
        let harness = try await ServiceHarness.make()
        let secondClient = InProcessChatTransport(endpoint: harness.service, context: ServiceSessionContext(
            principalID: harness.first.principalID, deviceID: ServiceDeviceID("other"),
            sessionID: ClientSessionID("two"),
            accounts: [harness.first.id]
        ))
        _ = try await secondClient.negotiate(.current)
        let first = try await harness.call(LoadConversations(), account: harness.first.id)
        let second = try await harness.call(LoadConversations(), account: harness.second.id)
        #expect(first.first?.id == second.first?.id)
        #expect(first.first?.title == "First")
        #expect(second.first?.title == "Second")
        let request = try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID("two")),
            payload: ListAccounts()
        )
        let visible = try await secondClient.exchange(request).value(for: ListAccounts.self)
        #expect(visible.map(\.id) == [harness.first.id])
        let page = try await harness.call(ReadEvents(cursor: nil, limit: 10), account: harness.first.id)
        let next = try await harness.call(
            ReadEvents(cursor: page.checkpoint, limit: 10),
            account: harness.first.id
        )
        #expect(next.snapshot == nil)
        #expect(next.events.isEmpty)
        #expect(await harness.service.activeRuntimeCount == 2)
        await harness.service.shutdown()
    }

    @Test func disableReenableAndRemoveChangeOnlyOwnedRuntime() async throws {
        let harness = try await ServiceHarness.make()
        let disabled = try await harness.call(SetAccountEnabled(enabled: false), account: harness.first.id)
        #expect(!disabled.isEnabled)
        #expect(await harness.service.activeRuntimeCount == 1)
        await #expect(throws: ServiceFailure.accountDisabled) {
            try await harness.call(LoadConversations(), account: harness.first.id)
        }
        #expect(try await harness.call(LoadConversations(), account: harness.second.id).first?
            .title == "Second")
        _ = try await harness.call(SetAccountEnabled(enabled: true), account: harness.first.id)
        try await harness.waitForAccounts()
        #expect(await harness.providers.made[harness.first.id] == 2)
        #expect(await harness.service.activeRuntimeCount == 2)
        _ = try await harness.call(RemoveAccount(), account: harness.first.id)
        #expect(await harness.providers.forgotten == [harness.first.id])
        #expect(await harness.service.activeRuntimeCount == 1)
        let remaining = try await harness.call(ListAccounts())
        #expect(remaining.map(\.id) == [harness.second.id])
        await harness.service.shutdown()
    }

    @Test func trustedContextCannotBorrowAnotherPrincipalsGrant() async throws {
        let harness = try await ServiceHarness.make()
        let request = try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID("forged"), accountID: harness.first.id),
            payload: LoadConversations()
        )
        let bytes = try await harness.service.handle(
            ServiceCodec.encode(request),
            context: ServiceSessionContext(
                principalID: ServicePrincipalID("stranger"), deviceID: ServiceDeviceID("mac"),
                sessionID: ClientSessionID("forged"),
                accounts: [harness.first.id]
            )
        )
        let response = try ServiceCodec.decode(ServiceResponse.self, from: bytes)
        #expect(response.result == .failure(.notAuthorized))
        await harness.service.shutdown()
    }

    @Test func persistedDisabledAccountDoesNotConstructProviderOnRestore() async throws {
        let harness = try await ServiceHarness.make()
        _ = try await harness.call(SetAccountEnabled(enabled: false), account: harness.first.id)
        await harness.service.shutdown()
        let registry = try SQLiteAccountRegistry(path: harness.directory
            .appendingPathComponent("registry.sqlite").path)
        let providers = TestProviders()
        let restarted = ChatService(
            registry: registry,
            storage: SQLiteServiceStorageFactory(directory: harness.directory),
            providers: providers
        )
        try await restarted.restore()
        #expect(await restarted.activeRuntimeCount == 1)
        #expect(await providers.made[harness.first.id] == nil)
        await restarted.shutdown()
    }
}
