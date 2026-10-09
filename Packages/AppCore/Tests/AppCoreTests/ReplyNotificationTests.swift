import ChatKit
import Foundation
import SyncEngine
import Testing
@testable import AppCore

/// Notifications for replies (threads spec §4.3), through a running session:
/// the coordinator gives the policy what the store knows about a reply's
/// thread, and a click on a reply opens its thread's panel at it.
///
/// "Not posted" is observed through a sentinel, as in
/// `NotificationCoordinatorTests`: announcements are decided one at a time, in
/// order, so once the top-level message sent after a reply is posted, the
/// reply has been decided.
@MainActor
struct ReplyNotificationTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
    private let space = Conversation.ID("space/1")
    private let other = Conversation.ID("space/2")
    private let topic = MessageThread.ID("topic:1")
    private let threads = Capabilities(canSendMessages: true, supportsThreads: true)

    /// A running session, holding the environment so the session lives as
    /// long as the test.
    private struct Running {
        let services: FakeLaunchServices
        let delivery: FakeNotificationDelivery
        let environment: AppEnvironment
        let model: ChatSessionModel
    }

    private struct SetUpFailed: Error {}

    /// Identified as `me`, listing both conversations with replies enabled,
    /// on a backend that supports threads.
    private func running() async throws -> Running {
        let services = try FakeLaunchServices(backendCapabilities: threads)
        let delivery = FakeNotificationDelivery()
        let environment = AppEnvironment(services: services, notifications: delivery)
        await environment.start()
        guard case let .running(model) = environment.phase else {
            throw SetUpFailed()
        }
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.conversationsChanged([
            Conversation(id: space, kind: .space, title: "Design", repliesEnabled: true),
            Conversation(id: other, kind: .space, title: "Ops", repliesEnabled: true)
        ]))
        #expect(await eventually { model.me == me.id && model.conversations.count == 2 })
        return Running(services: services, delivery: delivery, environment: environment, model: model)
    }

    /// In `space` every message is in `topic`; in `other`, each is its own topic.
    private func message(
        _ id: String, from sender: Member.ID, in conversation: Conversation.ID, isReply: Bool = false
    ) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation,
            threadID: conversation == space ? topic : MessageThread.ID("topic:\(id)"),
            sender: sender, text: "hello", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            isReply: isReply
        )
    }

    private func reply(_ id: String = "m:reply") -> Message {
        message(id, from: alice.id, in: space, isReply: true)
    }

    /// Emits `reply`, then a top-level sentinel in `other`, and returns what
    /// was posted once `count` notifications have been.
    private func posted(after reply: Message, in run: Running, count: Int) async -> [MessageNotification] {
        run.services.backend.emit(.messageReceived(reply))
        run.services.backend.emit(.messageReceived(message("m:sentinel-\(count)", from: alice.id, in: other)))
        _ = await eventually { await run.delivery.posted.count == count }
        return await run.delivery.posted
    }

    /// Nobody follows it and you never posted in it. Seen red with the
    /// policy's guard deleted (Step 10).
    @Test func aReplyInAThreadYouDoNotFollowIsNotPosted() async throws {
        let run = try await running()
        try run.services.store.apply([.upsertMessage(message("m:root", from: alice.id, in: space))])
        let notifications = await posted(after: reply(), in: run, count: 1)
        #expect(notifications.map(\.id) == ["m:sentinel-1"])
    }

    /// The server's word: posted, as a reply, without the conversation's
    /// Mark as Read (ruling 16).
    @Test func aReplyInAFollowedThreadIsPostedAsAReply() async throws {
        let run = try await running()
        try run.services.store.apply([
            .upsertMessage(message("m:root", from: alice.id, in: space)),
            .applyThreadChange(thread: topic, conversation: space, change: .followed(true))
        ])
        let notifications = await posted(after: reply(), in: run, count: 2)
        #expect(notifications.map(\.id) == ["m:reply", "m:sentinel-2"])
        #expect(notifications.first?.isReply == true)
        #expect(notifications.first?.offersMarkRead == false)
        #expect(notifications.last?.isReply == false)
    }

    /// Nobody has said, and you started the thread: posting follows it.
    @Test func aReplyInAThreadYouStartedIsPosted() async throws {
        let run = try await running()
        try run.services.store.apply([.upsertMessage(message("m:root", from: me.id, in: space))])
        let notifications = await posted(after: reply(), in: run, count: 2)
        #expect(notifications.map(\.id) == ["m:reply", "m:sentinel-2"])
    }

    @Test func aReplyThatMentionsYouIsPostedInAThreadYouDoNotFollow() async throws {
        let run = try await running()
        try run.services.store.apply([.upsertMessage(message("m:root", from: alice.id, in: space))])
        var mentioning = reply()
        mentioning.mentions = [Mention(target: .user(me.id), start: 0, length: 3)]
        let notifications = await posted(after: mentioning, in: run, count: 2)
        #expect(notifications.map(\.id) == ["m:reply", "m:sentinel-2"])
    }

    /// A panel the window does not draw is not on screen (session 58): the
    /// thread is open in the model, but its conversation offers no replies
    /// yet, so the reply is posted.
    @Test func aReplyIsPostedWhileItsPanelIsOpenButNotDrawn() async throws {
        let run = try await running()
        run.services.backend.emit(.conversationsChanged([
            Conversation(id: space, kind: .space, title: "Design"),
            Conversation(id: other, kind: .space, title: "Ops", repliesEnabled: true)
        ]))
        #expect(await eventually {
            run.model.conversations.first { $0.id == space }?.repliesEnabled == false
        })
        try run.services.store.apply([
            .upsertMessage(message("m:root", from: alice.id, in: space)),
            .applyThreadChange(thread: topic, conversation: space, change: .followed(true))
        ])
        run.model.select(space)
        run.environment.setActive(true)
        run.model.openThread(topic)
        #expect(run.model.threads.openThread == topic)
        let notifications = await posted(after: reply(), in: run, count: 2)
        #expect(notifications.map(\.id) == ["m:reply", "m:sentinel-2"])
        withExtendedLifetime(run) {}
    }

    /// On screen for a reply is its thread's panel in a visible window: the
    /// conversation alone is not, and a closed window is not.
    @Test func aReplyIsNotPostedOnlyWhileItsThreadsPanelIsOnScreen() async throws {
        let run = try await running()
        try run.services.store.apply([
            .upsertMessage(message("m:root", from: alice.id, in: space)),
            .applyThreadChange(thread: topic, conversation: space, change: .followed(true))
        ])
        run.model.select(space)
        run.environment.setActive(true)
        let viewing = await posted(after: reply("m:reply-viewing"), in: run, count: 2)
        #expect(viewing.map(\.id) == ["m:reply-viewing", "m:sentinel-2"])

        run.model.openThread(topic)
        #expect(run.model.threads.openThread == topic)
        let shown = await posted(after: reply("m:reply-shown"), in: run, count: 3)
        #expect(shown.map(\.id) == ["m:reply-viewing", "m:sentinel-2", "m:sentinel-3"])

        run.environment.setWindowOpen(false)
        let hidden = await posted(after: reply("m:reply-hidden"), in: run, count: 5)
        #expect(Array(hidden.map(\.id).suffix(2)) == ["m:reply-hidden", "m:sentinel-5"])
    }

    /// The click: the conversation, its thread's panel at the reply, the
    /// transcript scrolled to the thread's root, and the window asked for.
    @Test func clickingAReplysNotificationOpensItsThreadAtTheReply() async throws {
        let run = try await running()
        try run.services.store.apply([
            .upsertMessage(message("m:root", from: alice.id, in: space)), .upsertMessage(reply())
        ])
        run.delivery.respond.yield(.openMessage(space, reply().id))
        #expect(await eventually { run.model.threads.openThread == topic })
        #expect(run.model.selected == space)
        #expect(run.model.threads.scrollTarget == reply().id)
        #expect(run.model.scrollTarget == Message.ID("m:root"))
        #expect(run.environment.windowRequests == 1)
    }

    /// The click that launched the app asks for the window at once and opens
    /// the reply once the session has started.
    @Test func aReplysClickBeforeTheSessionExistsIsReplayedOnceItDoes() async throws {
        let services = try FakeLaunchServices(backendCapabilities: threads)
        let delivery = FakeNotificationDelivery()
        try services.store.apply([
            .upsertMessage(message("m:root", from: alice.id, in: space)), .upsertMessage(reply())
        ])
        let environment = AppEnvironment(services: services, notifications: delivery)
        delivery.respond.yield(.openMessage(space, reply().id))
        #expect(await eventually { environment.windowRequests == 1 })

        await environment.start()
        guard case let .running(model) = environment.phase else {
            Issue.record("expected .running to set the test up")
            return
        }
        #expect(await eventually { model.threads.openThread == topic })
        #expect(model.selected == space)
    }
}
