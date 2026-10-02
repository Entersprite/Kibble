import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `SyncEngine.attachmentData(_:size:)`: the one way a client reaches a
/// backend's attachment bytes, because nothing above `SyncEngine` talks to a
/// backend directly.
@Suite(.timeLimit(.minutes(1)))
struct AttachmentForwardingTests {
    @Test func theBackendsBytesComeThroughUnchanged() async throws {
        let image = FixtureWorld.acme.messages.flatMap(\.attachments).first { $0.isImage }
        let attachment = try #require(image)
        let backend = FakeBackend(world: .acme)
        let engine = try SyncEngine(backend: backend, store: ChatStore.inMemory())
        let viaEngine = try await engine.attachmentData(attachment, size: .preview)
        let direct = try await backend.attachmentData(attachment, size: .preview)
        #expect(viaEngine == direct)
        #expect(!viaEngine.isEmpty)
    }

    @Test func aRefusalIsThrownNotRecorded() async throws {
        let backend = FakeBackend(world: .acme, capabilities: Capabilities())
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let attachment = ChatKit.Attachment(id: "x", name: "x.png", contentType: "image/png")
        await #expect(throws: ChatError.unsupported(capability: "canFetchAttachments")) {
            _ = try await engine.attachmentData(attachment, size: .preview)
        }
        #expect(try store.lastError() == nil)
    }

    @Test func theDownloadIsForwardedToTheBackend() async throws {
        let pdf = FixtureWorld.acme.messages.flatMap(\.attachments).first { !$0.isImage }
        let attachment = try #require(pdf)
        let backend = FakeBackend(world: .acme)
        let engine = try SyncEngine(backend: backend, store: ChatStore.inMemory())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let progressLog = ProgressLogForTests()
        try await engine.downloadAttachment(attachment, to: destination) { progressLog.append($0) }
        let bytes = try Data(contentsOf: destination)
        #expect(!bytes.isEmpty)
        #expect(!progressLog.values.isEmpty)
        #expect(progressLog.values.last?.bytesReceived == progressLog.values.last?.totalBytes)
    }
}

/// Helper for tracking progress callbacks in tests.
final class ProgressLogForTests: @unchecked Sendable {
    private var lock = NSLock()
    private var _values: [AttachmentProgress] = []

    var values: [AttachmentProgress] {
        lock.withLock { _values }
    }

    func append(_ progress: AttachmentProgress) {
        lock.withLock { _values.append(progress) }
    }
}
