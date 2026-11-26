import ChatAPI
import ChatKit
import Foundation
import Synchronization
import Testing
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
struct UploadProviderProgressTests {
    @Test func providerProgressTravelsThroughTheServiceAndOnlyAcknowledgementCompletesTheUpload(
    ) async throws {
        let harness = try await ClientHarness.make(uploads: true, providerUploadProgress: true)
        let backend = harness.backend(harness.first)
        let provider = try #require(await harness.providers.progressBackend(harness.first.id))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 8).write(to: file)
        let updates = Mutex<[AttachmentProgress]>([])
        let uploading = Task { try await backend.uploadAttachment(OutgoingAttachment(
            id: "chosen", file: file, name: "file", contentType: "application/octet-stream", byteSize: 8
        ), to: .init("same"), progress: { value in updates.withLock { $0.append(value) } }) }
        try await eventually { await provider.held }
        #expect(updates.withLock { $0.last } == AttachmentProgress(bytesReceived: 8, totalBytes: 16))
        await provider.report(3)
        try await eventually { updates.withLock { $0.last?.bytesReceived == 11 } }
        await provider.report(2)
        await provider.report(8)
        try await eventually { updates.withLock { $0.last?.bytesReceived == 15 } }
        #expect(updates.withLock { $0.allSatisfy { $0.bytesReceived < 16 && $0.totalBytes == 16 } })
        await provider.release()
        #expect(try await uploading.value.byteSize == 8)
        let snapshot = updates.withLock { $0 }
        #expect(snapshot.map(\.bytesReceived) == snapshot.map(\.bytesReceived).sorted())
        #expect(snapshot.last == AttachmentProgress(bytesReceived: 16, totalBytes: 16))
        #expect(snapshot.filter { $0.bytesReceived == 16 }.count == 1)
        await backend.disconnect()
        await harness.service.shutdown()
    }

    @Test func disconnectDrainsTheProgressObserverWithoutPublishingCompletion() async throws {
        let harness = try await ClientHarness.make(uploads: true, providerUploadProgress: true)
        let backend = harness.backend(harness.first)
        let provider = try #require(await harness.providers.progressBackend(harness.first.id))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: file)
        let updates = Mutex<[Int]>([])
        let uploading = Task { try await backend.uploadAttachment(OutgoingAttachment(
            id: "chosen", file: file, name: "file", contentType: "text/plain", byteSize: 4
        ), to: .init("same"), progress: { value in updates.withLock { $0.append(value.bytesReceived) } }) }
        try await eventually { await provider.held }
        let generation = await backend.connectionGeneration
        let disconnecting = Task { await backend.disconnect() }
        try await eventually { await backend.connectionGeneration != generation }
        await provider.report(4)
        await provider.release()
        #expect(await uploading.result.isFailure)
        await disconnecting.value
        #expect(updates.withLock { !$0.contains(8) })
        #expect(await backend.uploadTasks.isEmpty)
        await harness.service.shutdown()
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self {
            return true
        }
        return false
    }
}
