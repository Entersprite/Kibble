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
}
