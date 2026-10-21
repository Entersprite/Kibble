import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct SharedReadTests {
    @Test func concurrentDirectoryCallersShareWorkAndCancellationDoesNotAbortIt() async throws {
        let harness = try await ReconciliationHarness.make()
        let runtime = try await ready(harness)
        let initial = await harness.backend.worldReads
        await harness.backend.holdNextWorld()
        let first = Task {
            try await runtime.fetchWorld(backend: harness.backend, epoch: runtime.currentEpoch)
        }
        try await authEventually { await harness.backend.worldHeld }
        let second = Task {
            try await runtime.fetchWorld(backend: harness.backend, epoch: runtime.currentEpoch)
        }
        try await authEventually {
            guard let pending = await runtime.reads.directory else { return false }
            return await pending.waitingCount == 2
        }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await harness.backend.worldReads == initial + 1)
        await harness.backend.releaseWorld()
        #expect(try await second.value.map(\.id) == [ReconciliationBackend.conversation])
        #expect(await harness.backend.worldReads == initial + 1)
        await harness.service.shutdown()
    }

    @Test func partialDirectoryResultKeepsCachedRows() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await ready(harness)
        let extra = Conversation.ID("extra")
        try await harness.addConversation(extra)
        await harness.backend.replaceDirectorySilently([], complete: false)
        let result = try await harness.call(LoadConversations())
        #expect(Set(result.map(\.id)) == [ReconciliationBackend.conversation, extra])
        #expect(try harness.storage.conversations().count == 2)
        await harness.service.shutdown()
    }

    @Test func liveReadProgressDoesNotRestartDirectoryRead() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await ready(harness)
        let initial = await harness.backend.worldReads
        await harness.backend.holdNextWorld()
        let query = Task { try await harness.call(LoadConversations()) }
        try await authEventually { await harness.backend.worldHeld }
        let position = ReconciliationBackend.date.addingTimeInterval(60)
        await harness.backend.emit(.readStateChanged(
            conversationID: ReconciliationBackend.conversation, lastReadAt: position, unread: 0
        ))
        try await authEventually {
            try harness.storage.conversation(ReconciliationBackend.conversation)?.readPosition == position
        }
        await harness.backend.releaseWorld()
        #expect(try await query.value.first?.readPosition == position)
        #expect(await harness.backend.worldReads == initial + 1)
        await harness.service.shutdown()
    }

    @Test func recentCanonicalDirectoryIsReusedButForcedReadStillReachesProvider() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await ready(harness)
        let initial = await harness.backend.worldReads
        _ = try await harness.call(LoadConversations(maximumAge: 30))
        #expect(await harness.backend.worldReads == initial)
        _ = try await harness.call(LoadConversations())
        #expect(await harness.backend.worldReads == initial + 1)
        await harness.service.shutdown()
    }

    private func ready(_ harness: ReconciliationHarness) async throws -> AccountRuntime {
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually {
            let world = await runtime.worldRefresh
            let read = await runtime.reads.directory
            return try world == nil && read == nil && harness.storage.conversations().count == 1
        }
        return runtime
    }
}
