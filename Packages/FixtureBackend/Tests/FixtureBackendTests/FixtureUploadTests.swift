import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// `FakeBackend.uploadAttachment(_:to:progress:)` and a send carrying what it
/// returned: deterministic, never reading the file, and refusing what it did
/// not hand out.
@Suite(.timeLimit(.minutes(1)))
struct FixtureUploadTests {
    private let dm = Conversation.ID("dm:1")

    private static let staged = OutgoingAttachment(
        id: "o-1", file: URL(fileURLWithPath: "/nonexistent/tread.png"), name: "tread.png",
        contentType: "image/png", byteSize: 400, width: 416, height: 300
    )

    private func connected(
        capabilities: Capabilities = .fixture
    ) async throws -> (FakeBackend, EventCollector) {
        let backend = FakeBackend(world: .minimal, capabilities: capabilities)
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(6)
        return (backend, collector)
    }

    @Test func anUploadThenASendLandsTheAttachmentOnTheMessage() async throws {
        let (backend, collector) = try await connected()
        let seen = ProgressLog()
        let uploaded = try await backend.uploadAttachment(Self.staged, to: dm) { seen.append($0) }
        #expect(uploaded.name == "tread.png")
        #expect(uploaded.width == 416)
        #expect(seen.values.last == AttachmentProgress(bytesReceived: 400, totalBytes: 400))
        try await backend.send(.sendMessage(
            conversationID: dm, threadID: nil, text: "", localID: "d-1", attachments: [uploaded]
        ))
        guard case let .messageReceived(message) = await collector.nextOne() else {
            Issue.record("expected messageReceived")
            return
        }
        #expect(message.attachments == [uploaded])
        #expect(try await backend.attachmentData(uploaded, size: .preview) == FixtureImage.png)
    }

    @Test func aSendNamingAnAttachmentNeverUploadedIsRefused() async throws {
        let (backend, _) = try await connected()
        let stranger = Attachment(id: "nope", name: "x.png", contentType: "image/png")
        await #expect(throws: ChatError.self) {
            try await backend.send(.sendMessage(
                conversationID: dm, threadID: nil, text: "", localID: nil, attachments: [stranger]
            ))
        }
    }

    @Test func withoutTheCapabilityTheUploadIsRefused() async throws {
        var capabilities = Capabilities.fixture
        capabilities.canSendAttachments = false
        let (backend, _) = try await connected(capabilities: capabilities)
        await #expect(throws: ChatError.unsupported(capability: "canSendAttachments")) {
            _ = try await backend.uploadAttachment(Self.staged, to: dm) { _ in }
        }
    }
}
