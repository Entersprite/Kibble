import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
struct UnreadBadgeWiringTests {
    @Test func theFilterDefaultsToBadgeOnlyAndRestoresAcrossNavigationAndRelaunch() async throws {
        let suite = "unread-filter-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = try AppEnvironment(services: FakeLaunchServices(), preferences: preferences)
        await first.start()
        let unread = try #require(first.actions.unread)
        unread.show()
        #expect(first.sceneState.unread.filter == .badgeOnly)

        unread.setFilter(.all)
        #expect(first.sceneState.unread.filter == .all)
        first.runningModel?.showMentions()
        #expect(!first.sceneState.unread.showing)
        unread.show()
        #expect(first.sceneState.unread.filter == .all)
        await first.runningModel?.stop()

        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        let next = try AppEnvironment(services: FakeLaunchServices(), preferences: reopenedDefaults)
        await next.start()
        try #require(next.actions.unread).show()
        #expect(next.sceneState.unread.filter == .all)
        await next.runningModel?.stop()
    }

    @Test func badgeOnlyMatchesTheDockAndMarksLocallyWithReceiptsWithheld() async throws {
        let services = try FakeLaunchServices(
            arguments: LaunchArguments(backend: .fixture),
            backendCapabilities: Capabilities(canMarkRead: true, supportsThreads: true)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        let model = try #require(environment.runningModel)
        let badge = Conversation.ID("dm/badge")
        let other = Conversation.ID("dm/unbadged")
        let head = Date(timeIntervalSince1970: 1_790_000_000)
        let me = Member(id: .init("me"), kind: .human)
        let sender = Member.ID("other")
        let root = Message(
            id: .init("badge-root"), conversationID: badge, threadID: .init("topic"),
            sender: sender, text: "Root", createdAt: head
        )
        let reply = Message(
            id: .init("badge-reply"), conversationID: badge, threadID: root.threadID,
            sender: sender, text: "Reply", createdAt: head.addingTimeInterval(1), isReply: true
        )
        let unbadged = Message(
            id: .init("unbadged"), conversationID: other, threadID: .init("other-topic"),
            sender: sender, text: "Unbadged", createdAt: head
        )
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.conversationsChanged([badge, other].map { unreadRoom($0, at: head) }))
        services.backend.emit(.connectionStateChanged(.connected))
        try #require(await eventually { environment.canEditNotificationRules && environment.badgeCount == 2 })
        environment.settings.update(NotificationRule(countsInBadge: false), for: .conversation(other))
        environment.settings.update(NotificationRule(readReceipts: false), for: .conversation(badge))
        try services.store.apply([
            .upsertMessage(root), .upsertMessage(reply), .upsertMessage(unbadged),
            .applyThreadChange(
                thread: root.threadID,
                conversation: badge,
                change: .counted(messages: 2, unread: 1)
            )
        ])
        model.showUnread()
        try #require(await eventually { environment.sceneState.unread.messages?.count == 3 })
        let scene = environment.sceneState.unread
        #expect(environment.badgeCount == 1)
        #expect(scene.messages?.filter { scene.shows($0, in: .badgeOnly) } == [root])

        let markAll = try #require(environment.actions.unread?.markAllRead)
        markAll(.badgeOnly)
        #expect(environment.badgeCount == 0)
        #expect(Set(environment.sceneState.unread.messages ?? []) == [reply, unbadged])
        #expect(environment.sceneState.conversations.first { $0.id == badge }?.hasUnread == false)
        await model.stop()
    }

    private func unreadRoom(_ id: Conversation.ID, at head: Date) -> Conversation {
        Conversation(
            id: id, kind: .directMessage, hasUnread: true,
            readPosition: head.addingTimeInterval(-60), repliesEnabled: true, latestMainMessageAt: head
        )
    }

    @Test func markAllClearsTheBadgeForAConversationWithoutInboxRows() async throws {
        let services = try FakeLaunchServices(
            arguments: LaunchArguments(backend: .fixture),
            backendCapabilities: Capabilities(canMarkRead: true)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        let model = try #require(environment.runningModel)
        let me = Member(id: .init("me"), kind: .human)
        let head = Date(timeIntervalSince1970: 1_790_000_000)
        let conversation = Conversation(
            id: .init("dm/1"), kind: .directMessage, hasUnread: true,
            readPosition: head.addingTimeInterval(-60), latestMainMessageAt: head
        )
        services.backend.emit(.selfIdentified(me))
        services.backend.emit(.conversationsChanged([conversation]))
        services.backend.emit(.connectionStateChanged(.connected))
        model.showUnread()
        try #require(await eventually {
            environment.badgeCount == 1 && environment.canEditNotificationRules &&
                environment.sceneState.unread.messages == [] && !environment.sceneState.unread.isLoading
        })
        #expect(environment.sceneState.unread.badgeConversations == [conversation.id])

        let markAll = try #require(environment.actions.unread?.markAllRead)
        markAll(.all)
        let command = ChatCommand.markRead(conversationID: conversation.id, upTo: head)
        #expect(environment.badgeCount == 0)
        #expect(environment.sceneState.unread.badgeConversations.isEmpty)
        #expect(environment.sceneState.unread.conversationsWithUnread.isEmpty)
        #expect(!services.backend.sent.contains(command))
        try #require(await eventually(timeout: .seconds(5)) {
            services.backend.sent.contains(command) && !model.isMarkingAllUnread
        })
        #expect(environment.badgeCount == 0)

        // The first submission returned without a read position. Reconnect retries it without reviving the
        // badge.
        let offline = ConnectionState.reconnecting(attempt: 1, issue: nil, detail: nil)
        services.backend.emit(.connectionStateChanged(offline))
        try #require(await eventually { model.connectionState == offline })
        services.backend.emit(.connectionStateChanged(.connected))
        try #require(await eventually(timeout: .seconds(5)) {
            services.backend.sent.count { $0 == command } == 2
        })
        services.backend.emit(.readStateChanged(conversationID: conversation.id, lastReadAt: head, unread: 0))
        #expect(await eventually { environment.badgeCount == 0 })
        await model.stop()
    }
}
