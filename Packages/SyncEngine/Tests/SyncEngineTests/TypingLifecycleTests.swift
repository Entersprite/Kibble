import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

struct TypingLifecycleTests {
    struct Harness {
        let engine: SyncEngine
        let backend: RecordingBackend
        let store: ChatStore
        let conversation: Conversation
        let me: Member.ID
    }

    private func harness(expiry: Duration = .seconds(6), idle: Duration = .seconds(4)) async throws
        -> Harness {
        let world = FixtureWorld.minimal
        let backend = RecordingBackend(world: world)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(
            backend: backend,
            store: store,
            typingTiming: TypingTiming(expiry: expiry, idle: idle)
        )
        var settings = NotificationSettings()
        settings.setRule(
            NotificationRule(sharesTyping: true),
            for: .global,
            at: world.startedAt,
            by: "test"
        )
        engine.typingPrivacy.set(settings)
        try await engine.start()
        for _ in 0 ..< 1000 {
            if try store.connectionState() == .connected {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(store.connectionState() == .connected)
        let conversation = try #require(world.conversations.first)
        // Explicit setup proves the submission gate has the selected conversation before activity.
        try store.apply([.replaceConversations(world.conversations)])
        return Harness(
            engine: engine,
            backend: backend,
            store: store,
            conversation: conversation,
            me: world.me
        )
    }

    private func typingCommands(_ backend: RecordingBackend) async -> [Bool] {
        await backend.commands.compactMap { command in
            if case let .setTyping(_, _, typing) = command {
                return typing
            }
            return nil
        }
    }

    private func waitForCount(_ count: Int, on backend: RecordingBackend) async throws {
        for _ in 0 ..< 1000 {
            if await typingCommands(backend).count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Typing submission did not complete")
    }

    @Test func directSubmissionAlsoChecksTypingPrivacy() async throws {
        let context = try await harness()
        context.engine.typingPrivacy.set(nil)
        let submitted = await context.engine.submit(.setTyping(
            conversationID: context.conversation.id,
            threadID: nil,
            isTyping: true
        ))
        #expect(!submitted)
        #expect(await typingCommands(context.backend).isEmpty)
        await context.engine.stop()
    }

    @Test func slowStartThenPrivacyOffSendsStopWithoutPublishingAgain() async throws {
        let context = try await harness()
        let engine = context.engine
        let backend = context.backend
        let conversation = context.conversation
        let me = context.me
        await backend.holdSubmissions(true)
        let update = TypingUpdate(conversationID: conversation.id, member: me, isTyping: true)
        await engine.updateTyping(update, in: conversation)
        try await waitForCount(1, on: backend)
        engine.typingPrivacy.set(nil)
        await engine.typingSettingsChanged()
        await backend.holdSubmissions(false)
        await backend.releaseHeldSubmission()
        try await waitForCount(2, on: backend)
        let commands = await typingCommands(backend)
        #expect(commands == [true, false])
        await engine.updateTyping(update, in: conversation)
        #expect(await typingCommands(backend) == commands)
        await engine.stop()
    }

    @Test func anotherComposerBlurCannotStopTheActiveThread() async throws {
        let context = try await harness()
        let engine = context.engine
        let backend = context.backend
        let conversation = context.conversation
        let me = context.me
        let thread = MessageThread.ID("thread")
        await engine.updateTyping(TypingUpdate(
            conversationID: conversation.id,
            threadID: thread,
            member: me,
            isTyping: true
        ), in: conversation)
        try await waitForCount(1, on: backend)
        await engine.endTyping(in: conversation.id, thread: nil)
        #expect(await engine.desiredTyping?.threadID == thread)
        await engine.endTyping(in: conversation.id, thread: thread)
        try await waitForCount(2, on: backend)
        #expect(await typingCommands(backend) == [true, false])
        await engine.stop()
    }

    @Test func duplicateEditsCoalesceAndIdleStops() async throws {
        let context = try await harness(idle: .milliseconds(30))
        let engine = context.engine
        let backend = context.backend
        let conversation = context.conversation
        let me = context.me
        let update = TypingUpdate(conversationID: conversation.id, member: me, isTyping: true)
        for _ in 0 ..< 20 {
            await engine.updateTyping(update, in: conversation)
        }
        try await waitForCount(2, on: backend)
        #expect(await typingCommands(backend) == [true, false])
        await engine.stop()
    }

    @Test func lostStopExpiresAndSessionStopErasesActivity() async throws {
        let context = try await harness(expiry: .milliseconds(20))
        let engine = context.engine
        let store = context.store
        let conversation = context.conversation
        let update = TypingUpdate(conversationID: conversation.id, member: Member.ID("other"), isTyping: true)
        await engine.handle(.scopedTypingChanged(update))
        #expect(try store.activity(in: conversation.id).typing == [update])
        for _ in 0 ..< 1000 {
            if try store.activity(in: conversation.id).typing.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(try store.activity(in: conversation.id).typing.isEmpty)
        await engine.handle(.scopedTypingChanged(update))
        await engine.stop()
        #expect(try store.activity(in: conversation.id).typing.isEmpty)
    }
}
