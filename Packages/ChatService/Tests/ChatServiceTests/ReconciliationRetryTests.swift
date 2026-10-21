import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct ReconciliationRetryTests {
    @Test func temporaryContentionRetriesWithoutPublishingAConnectionError() async throws {
        let harness = try await ReconciliationHarness.make()
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await idle(runtime)
        let checkpoint = try harness.storage.checkpoint()
        let reads = await harness.backend.worldReads
        await harness.backend.failNextWorldReads(2)
        await harness.backend.emit(.gap(scope: .everything, reason: "fixture"))
        try await authEventually { await harness.backend.worldReads == reads + 3 }
        try await idle(runtime)
        let page = try harness.storage.readEvents(after: checkpoint, limit: 256)
        #expect(!page.events.contains {
            if case .backendError = $0.event {
                true
            } else {
                false
            }
        })
        #expect(try harness.storage.conversations().count == 1)
        await harness.service.shutdown()
    }

    @Test(arguments: [ServiceFailure.overloaded, .notAuthorized])
    func persistentOrNonRetryableFailuresRemainVisible(_ failure: ServiceFailure) async throws {
        let harness = try await ReconciliationHarness.make()
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await idle(runtime)
        let checkpoint = try harness.storage.checkpoint()
        let reads = await harness.backend.worldReads
        await harness.backend.failNextWorldReads(10, with: failure)
        await harness.backend.emit(.gap(scope: .everything, reason: "fixture"))
        try await authEventually {
            try harness.storage.readEvents(after: checkpoint, limit: 256).events.contains {
                if case .backendError = $0.event {
                    true
                } else {
                    false
                }
            }
        }
        try await idle(runtime)
        #expect(await harness.backend.worldReads == reads + (failure == .overloaded ? 3 : 1))
        await harness.service.shutdown()
    }

    @Test func stoppingTheAccountCancelsPendingRetryWork() async throws {
        let harness = try await ReconciliationHarness.make()
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await idle(runtime)
        let reads = await harness.backend.worldReads
        await harness.backend.failNextWorldReads(10)
        await harness.backend.emit(.gap(scope: .everything, reason: "fixture"))
        try await authEventually { await harness.backend.worldReads == reads + 1 }
        _ = try await harness.call(SetAccountEnabled(enabled: false))
        #expect(await harness.backend.worldReads == reads + 1)
        #expect(await harness.service.activeRuntimeCount == 0)
        await harness.service.shutdown()
    }

    private func idle(_ runtime: AccountRuntime) async throws {
        try await authEventually {
            let task = await runtime.worldRefresh
            let rows = try await runtime.storage.conversations()
            return task == nil && rows.count == 1
        }
    }
}
