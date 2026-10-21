import ChatKit
import DesignSystem
import Foundation
import SyncEngine
import Testing
@testable import AppCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ComposerPersistenceTests {
    @Test func draftsSurviveReopeningAndEraseWithTheirAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("replica.sqlite").path
        let store = try ChatStore.onDisk(at: path)
        var failures = 0
        let writer = ComposerPersistence(store: store) { _ in failures += 1 }
        let conversation = Conversation.ID("conversation")
        var original = ComposerDraft()
        original.edit("  hello @")
        original.pick(.user(Member.ID("reader")), name: "Reader")
        original.moveCaret(to: 2)
        let address = ComposerDraftAddress(conversation: conversation, thread: MessageThread.ID("thread"))
        let snapshot = original.snapshot(at: address)
        writer.save([ComposerSnapshot(conversation: conversation, text: "superseded")])
        writer.save([snapshot])
        await writer.finish()
        writer.save([])
        await writer.finish()
        #expect(failures == 0)
        let reopened = try ChatStore.onDisk(at: path)
        #expect(try reopened.composerDrafts() == [snapshot])
        let restored = ComposerDraft(snapshot: snapshot)
        #expect(restored.text == original.text)
        #expect(restored.tokens == original.tokens)
        #expect(restored.caret == 2)
        #expect(try ChatStore.inMemory().composerDrafts().isEmpty)
        try reopened.erase()
        #expect(try reopened.composerDrafts().isEmpty)
    }

    @Test func disablingRestoresDraftsOnEnableAndSignOutErasesThem() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        await environment.start()
        let address = ComposerDraftAddress(
            conversation: Conversation.ID("same"),
            thread: MessageThread.ID("reply")
        )
        var draft = ComposerDraft()
        draft.edit("keep after disabling")
        let retired = environment.actions.preserveDraft
        retired?(address, draft)
        try await environment.detachClient(erasingPrivateData: false)
        #expect(try services.store.composerDrafts().first?.text == draft.text)
        retired?(address, ComposerDraft())
        await environment.start()
        retired?(address, ComposerDraft())
        #expect(environment.sceneState.composerDrafts[address]?.text == draft.text)
        try await environment.detachClient(erasingPrivateData: true)
        #expect(try services.store.composerDrafts().isEmpty)
        retired?(address, draft)
        #expect(try services.store.composerDrafts().isEmpty)
    }

    @Test func editingPersistsTheSetAsideCompositionAndClearedDraftsStayCleared() async throws {
        let store = try ChatStore.inMemory()
        let writer = ComposerPersistence(store: store) { _ in Issue.record("unexpected save failure") }
        let address = ComposerDraftAddress(conversation: Conversation.ID("conversation"))
        var draft = ComposerDraft()
        draft.edit("unsent")
        draft.beginEditing(Message.ID("old"), with: ComposedMessage(text: "editing a sent message"))
        writer.save([draft.snapshot(at: address)])
        await writer.finish()
        #expect(try store.composerDrafts().first?.text == "unsent")
        let next = ComposerPersistence(store: store) { _ in Issue.record("unexpected save failure") }
        next.save([])
        await next.finish()
        #expect(try store.composerDrafts().isEmpty)
    }

    @Test func storageRefusalIsReportedAndDoesNotReplaceSavedDrafts() async throws {
        let store = try ChatStore.inMemory()
        let original = ComposerSnapshot(conversation: Conversation.ID("a"), text: "saved")
        try store.saveComposerDrafts([original])
        var failures = 0
        let writer = ComposerPersistence(store: store) { _ in failures += 1 }
        writer.save([ComposerSnapshot(
            conversation: Conversation.ID("b"),
            text: String(repeating: "x", count: 1_048_577)
        )])
        await writer.finish()
        #expect(failures == 1)
        #expect(try store.composerDrafts() == [original])
    }
}
