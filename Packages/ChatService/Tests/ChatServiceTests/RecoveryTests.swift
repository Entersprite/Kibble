import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

struct RecoveryTests {
    private struct PartialStorage: ServiceStorageFactory {
        let backing: SQLiteServiceStorageFactory
        let refused: ConnectedAccountID
        func open(_ account: ConnectedAccountID) throws -> any ServiceAccountStorage {
            guard account != refused else { throw ServiceFailure.internalFailure }
            return try backing.open(account)
        }

        func erase(_ account: ConnectedAccountID) throws {
            try backing.erase(account)
        }
    }

    @Test func retiredAccountIDCannotBeReassignedEvenToItsPreviousOwner() throws {
        let registry = try SQLiteAccountRegistry(path: ":memory:")
        let record = AccountRecord(
            id: ConnectedAccountID("retired"), principalID: ServicePrincipalID("owner"),
            selfID: Member.ID("self"), label: "Account", credentialGeneration: "generation"
        )
        try registry.save(record)
        try registry.remove(record.id)
        #expect(throws: ServiceFailure.operationConflict) { try registry.save(record) }
        #expect(try registry.accounts().isEmpty)
    }

    @Test func failedRemovalRemainsVisibleAndCanBeRetried() async throws {
        let harness = try await ServiceHarness.make()
        await harness.service.shutdown()
        let providers = TestProviders(forgetFailures: 1)
        let service = try await restarted(harness, providers: providers)
        let context = context(harness)
        let failed = try await call(
            RemoveAccount(),
            service: service,
            context: context,
            account: harness.first.id
        )
        #expect(failed.result == .failure(.internalFailure))
        let accounts = try await call(ListAccounts(), service: service, context: context)
            .value(for: ListAccounts.self)
        #expect(accounts.first { $0.id == harness.first.id }?.isRemoving == true)
        #expect(await service.activeRuntimeCount == 1)
        let retried = try await call(
            RemoveAccount(),
            service: service,
            context: context,
            account: harness.first.id
        )
        #expect(try retried.result == .success(ServiceCodec.value(ServiceUnit())))
        #expect(await providers.forgotten == [harness.first.id])
        await service.shutdown()
    }

    @Test func restoreResumesRemovalAndABrokenAccountDoesNotBlockHealthyAccounts() async throws {
        let harness = try await ServiceHarness.make()
        await harness.service.shutdown()
        let registry = try SQLiteAccountRegistry(path: harness.directory
            .appendingPathComponent("registry.sqlite").path)
        let providers = TestProviders()
        let service = ChatService(
            registry: registry,
            storage: PartialStorage(
                backing: SQLiteServiceStorageFactory(directory: harness.directory),
                refused: harness.first.id
            ),
            providers: providers
        )
        try await service.restore()
        #expect(await service.activeRuntimeCount == 1)
        await service.shutdown()
        var removing = harness.first
        removing.isRemoving = true
        removing.isEnabled = false
        try registry.save(removing)
        let recovered = try await restarted(harness, providers: providers)
        for _ in 0 ..< 1000 {
            if try registry.accounts().count == 1 {
                break
            }
            await Task.yield()
        }
        #expect(try registry.accounts().map(\.id) == [harness.second.id])
        #expect(await recovered.activeRuntimeCount == 1)
        #expect(await providers.forgotten == [harness.first.id])
        await recovered.shutdown()
    }

    @Test func disabledAccountPolicyAndOperationStatusDoNotStartAProvider() async throws {
        let harness = try await ServiceHarness.make()
        let operation = ServiceOperationID("durable")
        let store = try SQLiteServiceStorageFactory(directory: harness.directory).open(harness.first.id)
        let request = try ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID("reserved"),
                accountID: harness.first.id
            ),
            payload: SendCommand(
                operationID: operation,
                command: .loadMembers(conversationID: Conversation.ID("one"))
            )
        )
        _ = try store.reserve(operation, request: request)
        _ = try await harness.call(SetAccountEnabled(enabled: false), account: harness.first.id)
        let status = try await harness.call(GetOperation(operationID: operation), account: harness.first.id)
        #expect(status.state == "accepted")
        let first = try await harness.call(GetAccountPolicy(), account: harness.first.id)
        let second = try await harness.call(
            SetAccountPolicy(settings: NotificationSettings(), expectedRevision: first.revision),
            account: harness.first.id
        )
        #expect(second.revision != first.revision)
        #expect(await harness.providers.made[harness.first.id] == 1)
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.service.shutdown()
    }

    private func restarted(_ harness: ServiceHarness, providers: TestProviders) async throws -> ChatService {
        let service = try ChatService(
            registry: SQLiteAccountRegistry(path: harness.directory.appendingPathComponent("registry.sqlite")
                .path),
            storage: SQLiteServiceStorageFactory(directory: harness.directory), providers: providers
        )
        try await service.restore()
        return service
    }

    private func context(_ harness: ServiceHarness) -> ServiceSessionContext {
        ServiceSessionContext(
            principalID: harness.first.principalID,
            deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("client"),
            accounts: [
                harness.first.id,
                harness.second.id
            ]
        )
    }

    private func call(
        _ payload: some ServiceRequestPayload, service: ChatService, context: ServiceSessionContext,
        account: ConnectedAccountID? = nil
    ) async throws -> ServiceResponse {
        let request = try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID(UUID().uuidString), accountID: account),
            payload: payload
        )
        return try await ServiceCodec.decode(
            ServiceResponse.self,
            from: service.handle(ServiceCodec.encode(request), context: context)
        )
    }
}
