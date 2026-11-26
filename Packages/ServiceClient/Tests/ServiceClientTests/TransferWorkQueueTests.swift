import ChatAPI
import Foundation
import Testing
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
struct TransferWorkQueueTests {
    @Test func anUploadGetsTheNextSlotDuringAMediaBatchThenMediaContinues() async throws {
        let queue = TransferWorkQueue(maximumRunning: 1)
        let held = try await queue.acquire(.media)
        let media = Task { try await queue.acquire(.media) }
        defer { media.cancel(); Task { await queue.release(held) } }
        try await eventually { await queue.queuedCount == 1 }
        let upload = Task { try await queue.acquire(.upload) }
        defer { upload.cancel() }
        try await eventually { await queue.queuedCount == 2 }
        #expect(await queue.active.count == 1)
        await queue.release(held)
        try await eventually { await queue.queuedCount == 1 }
        let first = try #require(await queue.active.first)
        #expect(first.value == .upload)
        await queue.release(first.key)
        try await eventually { await queue.queuedCount == 0 }
        let second = try #require(await queue.active.first)
        #expect(second.value == .media)
        await queue.release(second.key)
        _ = try await upload.value
        _ = try await media.value
        #expect(await queue.active.isEmpty)
        #expect(await queue.queuedCount == 0)
    }

    @Test func mediaQueueOverflowLeavesUploadCapacityAndCanceledWaitersReleaseTheirPlace() async throws {
        let queue = TransferWorkQueue(maximumRunning: 1, maximumQueuedMedia: 1, maximumQueuedUploads: 1)
        let held = try await queue.acquire(.media)
        let media = Task { try await queue.acquire(.media) }
        defer { media.cancel(); Task { await queue.release(held) } }
        try await eventually { await queue.queuedCount == 1 }
        await #expect(throws: ServiceFailure.overloaded) { try await queue.acquire(.media) }
        let upload = Task { try await queue.acquire(.upload) }
        defer { upload.cancel() }
        try await eventually { await queue.queuedCount == 2 }
        await #expect(throws: ServiceFailure.overloaded) { try await queue.acquire(.upload) }
        media.cancel()
        await #expect(throws: CancellationError.self) { try await media.value }
        #expect(await queue.queuedCount == 1)
        #expect(await queue.active.count == 1)
        await queue.release(held)
        try await eventually { await queue.active.values.contains(.upload) }
        try await queue.release(upload.value)
        #expect(await queue.active.isEmpty)
        #expect(await queue.queuedCount == 0)
    }
}
