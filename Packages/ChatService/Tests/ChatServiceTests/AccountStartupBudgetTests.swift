import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct AccountStartupBudgetTests {
    @Test(arguments: [false, true]) func aTransientStartupFailureRetriesOnTheInstalledProvider(
        checkpointing: Bool
    ) async throws {
        let harness = try await ReconciliationHarness.make(
            checkpointing: checkpointing, startupFailures: [.transport("fixture offline")]
        )
        do {
            let runtime = try #require(await harness.service.runtimes[harness.record.id])
            let admission = await harness.service.providerStarts
            try await capacityEventually {
                let connection = await runtime.connection
                let activeCount = await admission.activeCount
                return connection == .reconnecting(attempt: 1, issue: nil, detail: nil) && activeCount == 0
            }
            try await capacityEventually { await runtime.connection == .connected }
            #expect(await harness.backend.startupAttempts == 2)
            #expect(await harness.backend.disconnects == 0)
        } catch {
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
    }

    @Test func shutdownCancelsABackingOffStartup() async throws {
        let harness = try await ReconciliationHarness.make(startupFailures: [
            .rateLimited(retryAfter: .seconds(30))
        ])
        do {
            let runtime = try #require(await harness.service.runtimes[harness.record.id])
            try await capacityEventually { await runtime.connection == .reconnecting(
                attempt: 1,
                issue: nil,
                detail: nil
            ) }
        } catch {
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
        #expect(await harness.backend.startupAttempts == 1)
        #expect(await harness.backend.disconnects == 1)
    }

    @Test func queuedDisableAvoidsConstructionAndShutdownDrainsAdmittedFactories() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: folder.appendingPathComponent("registry.sqlite").path)
        let accounts = (0 ..< 10).map { index in AccountRecord(
            id: .init("account-\(index)"), principalID: .init("owner"), selfID: .init("self-\(index)"),
            label: "Account", credentialGeneration: "fixture"
        ) }
        for account in accounts {
            try registry.save(account)
        }
        let providers = HeldCapacityProviders()
        let service = ChatService(
            registry: registry, storage: SQLiteServiceStorageFactory(directory: folder), providers: providers,
            maximumConcurrentProviderStarts: 2
        )
        try await service.restore()
        do {
            let admission = await service.providerStarts
            try await capacityEventually { await admission.waitingCount == 8 }
            #expect(await providers.constructing.count == 2)
            let constructing = await providers.constructing
            let queued = try #require(accounts.first { !constructing.contains($0.id) })
            let request = try ServiceRequest(header: .init(
                requestID: .init(UUID().uuidString), accountID: queued.id,
                accountRevision: queued.currentRevision
            ), payload: SetAccountEnabled(enabled: false))
            let reply = try await service.handle(ServiceCodec.encode(request), context: .init(
                principalID: .init("owner"), deviceID: .init("device"), sessionID: .init("client"),
                accounts: [], hasAllAccountAccess: true
            ))
            let response = try ServiceCodec.decode(ServiceResponse.self, from: reply)
            #expect(try response.value(for: SetAccountEnabled.self).isEnabled == false)
            #expect(await admission.waitingCount == 7)
            #expect(await providers.constructing == constructing)
            let shutdown = Task { await service.shutdown() }
            try await capacityEventually { await admission.waitingCount == 0 }
            #expect(await admission.activeCount == 2)
            await providers.release()
            await shutdown.value
            #expect(await admission.activeCount == 0)
            #expect(await service.activeRuntimeCount == 0)
        } catch {
            await providers.release()
            await service.shutdown()
            throw error
        }
    }
}

private actor HeldCapacityProviders: AccountProviderFactory {
    private let providers = TestProviders()
    private(set) var constructing: Set<ConnectedAccountID> = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func makeProvider(for account: AccountRecord) async -> AccountProvider {
        constructing.insert(account.id)
        if !released {
            await withCheckedContinuation { waiting.append($0) }
        }
        return await providers.makeProvider(for: account)
    }

    func forgetCredentials(for _: AccountRecord) {}
    func release() {
        released = true
        let pending = waiting; waiting = []
        pending.forEach { $0.resume() }
    }
}
