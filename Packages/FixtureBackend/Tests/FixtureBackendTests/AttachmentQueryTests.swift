import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// `FakeBackend.attachmentData(_:size:)`: the same picture for every
/// attachment the world holds, so the app's Debug backend draws images with no
/// network and the same bytes on every run.
@Suite(.timeLimit(.minutes(1)))
struct AttachmentQueryTests {
    private let dm = Conversation.ID("dm:1")

    private static let image = ChatKit.Attachment(
        id: "fixture-upload-1", name: "funnel.png", contentType: "image/png", width: 320, height: 200
    )

    private func worldWithAnImage() -> FixtureWorld {
        var world = FixtureWorld.minimal
        world.messages.append(Message(
            id: Message.ID("with-image"),
            conversationID: dm,
            threadID: MessageThread.ID("with-image-topic"),
            sender: world.me,
            text: "",
            createdAt: world.startedAt,
            attachments: [Self.image]
        ))
        return world
    }

    @Test func anAttachmentInTheWorldIsServedAsTheFixturePNG() async throws {
        let backend = FakeBackend(world: worldWithAnImage())
        let preview = try await backend.attachmentData(Self.image, size: .preview)
        let original = try await backend.attachmentData(Self.image, size: .original)
        #expect(preview == FixtureImage.png)
        #expect(original == FixtureImage.png)
        #expect(preview.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func anAttachmentTheWorldDoesNotHoldIsRefused() async {
        let backend = FakeBackend(world: worldWithAnImage())
        let stranger = ChatKit.Attachment(id: "nobody-sent-this", name: "x.png", contentType: "image/png")
        await #expect(throws: ChatError.self) {
            _ = try await backend.attachmentData(stranger, size: .preview)
        }
    }

    @Test func aSparseCapabilitySetRefusesByName() async {
        let backend = FakeBackend(world: worldWithAnImage(), capabilities: Capabilities())
        await #expect(throws: ChatError.unsupported(capability: "canFetchAttachments")) {
            _ = try await backend.attachmentData(Self.image, size: .preview)
        }
    }

    /// So `--backend=fixture` shows both the picture and the file chip.
    @Test func theDemoWorldHasAnImageWithItsSizeAndAFile() {
        let attachments = FixtureWorld.acme.messages.flatMap(\.attachments)
        #expect(attachments.contains { $0.isImage && $0.width == 320 && $0.height == 200 })
        #expect(attachments.contains { !$0.isImage })
    }
}
