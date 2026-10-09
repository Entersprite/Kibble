import ChatKit
import DesignSystem
import Foundation
import SyncEngine
import Testing
@testable import AppCore

/// Threads in the running app (threads spec §5): the thread actions exist
/// only while a session runs on a backend that has threads (`CLAUDE.md`:
/// never draw a control the seam cannot honor), each reaches the model, and
/// the model's thread state reaches the scene.
@MainActor
struct ThreadsWiringTests {
    private let me = Member(id: Member.ID("users/me"), kind: .human, displayName: "Me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice")
    private let space = Conversation(
        id: Conversation.ID("space/1"), kind: .space, title: "Design", repliesEnabled: true
    )
    private let topic = MessageThread.ID("topic:1")

    private func running(supportsThreads: Bool) async throws -> AppEnvironment {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, supportsThreads: supportsThreads)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return environment
        }
        return environment
    }

    /// A session on a backend with threads, identified, listing `space`, with
    /// `space` selected.
    private func selected() async throws -> (AppEnvironment, FakeLaunchServices) {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, supportsThreads: true)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else { throw TestSetupFailure() }
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.membersResolved([alice]))
        services.backend.emit(.conversationsChanged([space]))
        #expect(await eventually {
            environment.sceneState.conversations.map(\.id) == [space.id] && environment.sceneState.me == me.id
        })
        environment.actions.select(space.id)
        #expect(environment.sceneState.selected == space.id)
        return (environment, services)
    }

    private func message(_ id: String, isReply: Bool = false) -> Message {
        Message(
            id: Message.ID(id), conversationID: space.id, threadID: topic, sender: alice.id,
            text: "hello", createdAt: Date(timeIntervalSince1970: 1_790_000_000), isReply: isReply
        )
    }

    @Test func withoutTheCapabilityNoThreadActionIsOffered() async throws {
        let environment = try await running(supportsThreads: false)
        #expect(environment.actions.threads == nil)
    }

    @Test func withTheCapabilityTheyAre() async throws {
        let environment = try await running(supportsThreads: true)
        #expect(environment.actions.threads != nil)
    }

    /// Before any thread is opened the scene has no panel and an empty list.
    @Test func aFreshSceneHasNoPanel() async throws {
        let environment = try await running(supportsThreads: true)
        #expect(environment.sceneState.threads.panel == nil)
        #expect(environment.sceneState.threads.showingList == false)
    }

    /// The Threads row is chosen as the Mentions row is: no conversation is.
    @Test func showingTheListChoosesTheThreadsRow() async throws {
        let (environment, _) = try await selected()
        environment.actions.threads?.showList()
        let state = environment.sceneState
        #expect(state.threads.showingList)
        #expect(state.sidebarSelection == .threads)
        #expect(state.selected == nil)
        withExtendedLifetime(environment) {}
    }

    /// A thread with no stored summary yet ("Reply in Thread" on a message
    /// nobody replied to) is one message, titled by its conversation.
    @Test func openingAThreadShowsItsPanelAndClosingHidesIt() async throws {
        let (environment, _) = try await selected()
        environment.actions.threads?.open(topic)
        let panel = environment.sceneState.threads.panel
        #expect(panel?.thread.id == topic)
        #expect(panel?.thread.replyCount == 1)
        #expect(panel?.conversationTitle == "Design")
        environment.actions.threads?.close()
        #expect(environment.sceneState.threads.panel == nil)
        withExtendedLifetime(environment) {}
    }

    /// With a stored summary, the panel and the marks read it.
    @Test func aStoredSummaryReachesThePanelAndTheMarks() async throws {
        let (environment, services) = try await selected()
        try services.store.apply([
            .applyThreadChange(
                thread: topic,
                conversation: space.id,
                change: .counted(messages: 3, unread: nil)
            )
        ])
        #expect(await eventually { environment.sceneState.threads.summaries[topic]?.replyCount == 3 })
        environment.actions.threads?.open(topic)
        #expect(environment.sceneState.threads.panel?.thread.replyCount == 3)
        withExtendedLifetime(environment) {}
    }

    /// A followed thread with a reply is a Threads list item, named by its
    /// conversation and its first message's sender, and counted in the badge.
    @Test func aFollowedThreadIsAListItemAndCountsInTheBadge() async throws {
        let (environment, services) = try await selected()
        try services.store.apply([
            .upsertMessage(message("m:root")),
            .upsertMessage(message("m:reply", isReply: true)),
            .applyThreadChange(thread: topic, conversation: space.id, change: .followed(true)),
            .applyThreadChange(
                thread: topic,
                conversation: space.id,
                change: .counted(messages: 2, unread: 1)
            )
        ])
        #expect(await eventually { environment.sceneState.threads.items.count == 1 })
        let state = environment.sceneState.threads
        #expect(state.items.first?.id == ThreadListItem.Key(conversation: space.id, thread: topic))
        #expect(state.items.first?.root.id == Message.ID("m:root"))
        #expect(state.items.first?.conversationTitle == "Design")
        #expect(state.items.first?.senderName == "Alice")
        #expect(state.unreadCount == 1)
        withExtendedLifetime(environment) {}
    }

    /// From the list, an item opens its conversation and its thread.
    @Test func openingAnItemSelectsItsConversationAndOpensItsThread() async throws {
        let (environment, _) = try await selected()
        environment.actions.threads?.showList()
        environment.actions.threads?.openItem(space.id, topic)
        #expect(environment.sceneState.sidebarSelection == .conversation(space.id))
        #expect(environment.sceneState.threads.panel?.thread.id == topic)
        withExtendedLifetime(environment) {}
    }

    /// A reply goes into the open thread; a follow waits for its answer; a
    /// Mark as Unread is sent from the reply it was chosen on.
    @Test func replyingFollowingAndMarkingReachTheBackend() async throws {
        let (environment, services) = try await selected()
        environment.actions.threads?.open(topic)
        environment.actions.threads?.sendReply(ComposedMessage(text: "on it"))
        #expect(await eventually {
            services.backend.sent.contains { command in
                guard case let .sendMessage(conversation, thread, text, _, _, _) = command
                else { return false }
                return conversation == space.id && thread == topic && text == "on it"
            }
        })
        environment.actions.threads?.setFollowed(true)
        #expect(environment.sceneState.threads.panel?.followPending == true)
        let reply = message("m:reply", isReply: true)
        environment.actions.threads?.markUnread(reply)
        #expect(await eventually {
            services.backend.sent.contains(
                .setThreadUnreadMark(conversationID: space.id, threadID: topic, at: reply.createdAt)
            )
        })
        withExtendedLifetime(environment) {}
    }
}
