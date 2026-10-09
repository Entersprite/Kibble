import ChatKit
import DesignSystem
import Foundation
import SyncEngine
import Testing
@testable import AppCore

/// The composer's paperclip and drop target as `AppEnvironment` offers them:
/// only when the backend can upload, staging what the picker answered, and
/// naming in a banner what cannot be sent.
@MainActor
struct StagingWiringTests {
    private func running(canUpload: Bool) async throws -> (AppEnvironment, FakeLaunchServices) {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, canSendAttachments: canUpload)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return (environment, services)
        }
        model.select(Conversation.ID("space/s-1"))
        return (environment, services)
    }

    private static func file(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "staging-\(UUID().uuidString)-\(name)")
        try Data("hello".utf8).write(to: url)
        return url
    }

    @Test func withoutTheCapabilityThereIsNoPaperclipAndNoDropTarget() async throws {
        let (environment, services) = try await running(canUpload: false)
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        #expect(environment.actions.composerAttachments == nil)
    }

    @Test func thePaperclipStagesWhatThePickerAnswered() async throws {
        let (environment, services) = try await running(canUpload: true)
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        let file = try Self.file("notes.txt")
        defer { try? FileManager.default.removeItem(at: file) }
        services.filesToSend = [file]
        let actions = try #require(environment.actions.composerAttachments)

        actions.choose()

        let staged = environment.sceneState.stagedAttachments
        #expect(staged.map(\.name) == [file.lastPathComponent])
        #expect(staged.first?.byteSize == 5)
        #expect(staged.first?.state == .ready)

        try actions.remove(#require(staged.first?.id))
        #expect(environment.sceneState.stagedAttachments.isEmpty)
    }

    /// The panel's +, chips and drops stage into the open thread, never the
    /// conversation, where Send would post them at the top level (session
    /// 60 review, Important 2).
    @Test func thePanelsPlusStagesIntoTheOpenThread() async throws {
        let services = try FakeLaunchServices(backendCapabilities: Capabilities(
            canSendMessages: true, supportsThreads: true, canSendAttachments: true
        ))
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return
        }
        // The panel needs its conversation in the list, and the fake loads none.
        let space = Conversation(
            id: Conversation.ID("space/s-1"), kind: .space, title: "Deploys", repliesEnabled: true
        )
        services.backend.emit(.conversationsChanged([space]))
        #expect(await eventually { model.conversations.count == 1 })
        model.select(space.id)
        model.openThread(MessageThread.ID("thread-1"))
        #expect(environment.sceneState.threads.panel != nil)
        let file = try Self.file("notes.txt")
        defer { try? FileManager.default.removeItem(at: file) }
        services.filesToSend = [file]
        let actions = try #require(environment.actions.threads?.attachments)

        actions.choose()

        let staged = environment.sceneState.threads.panel?.stagedAttachments ?? []
        #expect(staged.map(\.name) == [file.lastPathComponent])
        #expect(environment.sceneState.stagedAttachments.isEmpty)
        try actions.remove(#require(staged.first?.id))
        #expect(environment.sceneState.threads.panel?.stagedAttachments.isEmpty == true)
    }

    @Test func aDroppedFolderIsNamedInABannerAndNotStaged() async throws {
        let (environment, services) = try await running(canUpload: true)
        defer { try? FileManager.default.removeItem(at: services.attachmentDirectory) }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "staging-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try #require(environment.actions.composerAttachments).stage([folder])

        #expect(environment.sceneState.stagedAttachments.isEmpty)
        #expect(await eventually { environment.sceneState.lastError != nil })
    }

    @Test func progressBecomesAFraction() {
        let file = OutgoingAttachment(
            id: "a", file: URL(fileURLWithPath: "/a"), name: "a", contentType: "text/plain", byteSize: 10
        )
        let chips = AppEnvironment.composerAttachments([
            StagedAttachment(
                attachment: file,
                state: .uploading(AttachmentProgress(bytesReceived: 5, totalBytes: 10))
            ),
            StagedAttachment(
                attachment: file,
                state: .uploading(AttachmentProgress(bytesReceived: 5, totalBytes: nil))
            ),
            StagedAttachment(attachment: file, state: .uploading(nil)),
            StagedAttachment(attachment: file, state: .failed)
        ])
        #expect(chips.map(\.state) == [
            .uploading(fraction: 0.5), .uploading(fraction: nil), .uploading(fraction: nil), .failed
        ])
    }
}
