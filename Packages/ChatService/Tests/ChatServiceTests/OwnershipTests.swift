import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

struct OwnershipTests {
    private struct RefusedRegistry: AccountRegistry {
        func accounts() throws -> [AccountRecord] {
            throw ServiceFailure.internalFailure
        }

        func save(_ account: AccountRecord) {}
        func remove(_ account: ConnectedAccountID) {}
    }

    private struct RefusedLinks: AccountLinkRegistry {
        func accounts() -> [AccountRecord] {
            [LinkHarness.existing()]
        }

        func save(_ account: AccountRecord) {}
        func remove(_ account: ConnectedAccountID) {}
        func links() throws -> [AccountLinkRecord] {
            throw ServiceFailure.internalFailure
        }

        func saveLink(_ link: AccountLinkRecord) {}
        func commitLink(_ link: AccountLinkRecord, account: AccountRecord) {}
    }

    private actor HeldCleanup: AccountProviderFactory {
        let providers = TestProviders()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var began = false
        func makeProvider(for account: AccountRecord) async throws -> AccountProvider {
            await providers.makeProvider(for: account)
        }

        func forgetCredentials(for account: AccountRecord) async {
            began = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            released = true
            continuation?.resume(); continuation = nil
        }
    }

    private func ownership() throws -> FileServiceOwnership {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try FileServiceOwnership(file: folder.appendingPathComponent("service.lock"))
    }

    @Test func fileLeaseIsExclusiveAndAnOldReleaseCannotUnlockItsSuccessor() throws {
        let ownership = try ownership()
        let first = try ownership.acquire()
        #expect(throws: ServiceFailure.ownerBusy) { try ownership.acquire() }
        first.release()
        let second = try ownership.acquire()
        first.release()
        #expect(throws: ServiceFailure.ownerBusy) { try ownership.acquire() }
        second.release()
        let third = try ownership.acquire()
        third.release()
    }

    @Test func aSecondServiceCannotRestoreUntilTheFirstDrainsAndReleases() async throws {
        let ownership = try ownership()
        let registry = try SQLiteAccountRegistry(path: ":memory:")
        let factory = SQLiteServiceStorageFactory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let first = ChatService(
            registry: registry,
            storage: factory,
            providers: TestProviders(),
            ownership: ownership
        )
        let second = ChatService(
            registry: registry,
            storage: factory,
            providers: TestProviders(),
            ownership: ownership
        )
        try await first.restore()
        await #expect(throws: ServiceFailure.ownerBusy) { try await second.restore() }
        await first.shutdown()
        try await second.restore()
        await second.shutdown()
    }

    @Test func aRefusedRegistryReadReleasesTheLeaseAndShutdownCannotBeReversedByRestore() async throws {
        let ownership = try ownership()
        let factory = SQLiteServiceStorageFactory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let failed = ChatService(
            registry: RefusedRegistry(),
            storage: factory,
            providers: TestProviders(),
            ownership: ownership
        )
        await #expect(throws: ServiceFailure.internalFailure) { try await failed.restore() }
        let lease = try ownership.acquire()
        lease.release()
        await failed.shutdown()
        await #expect(throws: ServiceFailure.overloaded) { try await failed.restore() }
    }

    @Test func aRefusedLinkReadFailsBeforeStartingAnyAccountAndReleasesTheLease() async throws {
        let ownership = try ownership()
        let providers = TestProviders()
        let service = ChatService(
            registry: RefusedLinks(),
            storage: SQLiteServiceStorageFactory(directory: FileManager.default
                .temporaryDirectory),
            providers: providers,
            ownership: ownership
        )
        await #expect(throws: ServiceFailure.internalFailure) { try await service.restore() }
        #expect(await service.activeRuntimeCount == 0)
        #expect(await providers.made.isEmpty)
        let lease = try ownership.acquire()
        lease.release()
        await service.shutdown()
    }

    @Test func shutdownRetainsOwnershipUntilAnExplicitRemovalFinishesCleanup() async throws {
        let harness = try await ServiceHarness.make()
        await harness.service.shutdown()
        let ownership = try ownership()
        let cleanup = HeldCleanup()
        let service = try ChatService(
            registry: SQLiteAccountRegistry(path: harness.directory.appendingPathComponent("registry.sqlite")
                .path),
            storage: SQLiteServiceStorageFactory(directory: harness.directory), providers: cleanup,
            ownership: ownership
        )
        try await service.restore()
        let context = ServiceSessionContext(
            principalID: harness.first.principalID,
            deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("session"),
            accounts: [harness.first.id]
        )
        let remove = try ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID("remove"), accountID: harness.first.id,
                accountRevision: harness.first.currentRevision
            ),
            payload: RemoveAccount()
        )
        let removal = Task { try await service.handle(ServiceCodec.encode(remove), context: context) }
        defer { Task { await cleanup.finish() } }
        let clock = ContinuousClock()
        let removalDeadline = clock.now + .seconds(5)
        while await !(cleanup.began),
              clock.now < removalDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await cleanup.began)
        let shutdown = Task { await service.shutdown() }
        let shutdownDeadline = clock.now + .seconds(5)
        while await service.activeRuntimeCount != 0, clock.now < shutdownDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await service.activeRuntimeCount == 0)
        #expect(throws: ServiceFailure.ownerBusy) { try ownership.acquire() }
        await cleanup.finish()
        _ = try await removal.value
        await shutdown.value
        let replacement = try ownership.acquire()
        replacement.release()
    }
}
