import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct LinkedAccountReadinessTests {
    @Test func profilesArrivingBeforeTheFirstWorldCommitDoNotRetireTheRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = try SQLiteAccountRegistry(path: directory.appendingPathComponent("registry.sqlite")
            .path)
        let record = LinkHarness.existing()
        try registry.save(record)
        let backend = ReconciliationBackend()
        await backend.holdNextWorld()
        let service = ChatService(
            registry: registry, storage: SQLiteServiceStorageFactory(directory: directory),
            providers: ReconciliationProviders(backend: backend)
        )
        try await service.restore()
        defer { Task { await backend.releaseWorld(); await service.shutdown() } }
        try await authEventually { await backend.worldHeld }
        let runtime = try #require(await service.runtimes[record.id])
        let storage = await runtime.storage
        #expect(try storage.conversations().isEmpty)
        let member = Member(id: Member.ID("peer"), kind: .human, displayName: "Ada")
        await backend.emit(.membersResolved([member]))
        try await authEventually {
            let snapshot = try storage.readEvents(after: nil, limit: 256).snapshot ?? []
            return snapshot.contains { event in
                if case let .membersResolved(members) = event {
                    members.contains(member)
                } else {
                    false
                }
            }
        }
        #expect(try storage.conversations().isEmpty)
        #expect(await service.activeRuntimeCount == 1)
        await backend.releaseWorld()
        try await authEventually { try storage.conversations().count == 1 }
        #expect(await service.activeRuntimeCount == 1)
        #expect(await runtime.quarantinedForSubscription == false)
        await service.shutdown()
    }

    @Test func newlyLinkedAccountPublishesReadyStateAlongsideAnExistingAccount() async throws {
        let existing = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [existing])
        let link = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("new-link")))
        _ = try await harness.call(CompleteAccountLink(linkID: link.id))
        try await authEventually {
            let accounts = try await harness.call(ListAccounts())
            return accounts.count == 2 && accounts.allSatisfy { $0.isReady && $0.runtimeID != nil }
        }
        await harness.service.shutdown()
    }
}
