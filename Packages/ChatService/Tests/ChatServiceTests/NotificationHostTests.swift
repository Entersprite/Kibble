import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct NotificationHostTests {
    @Test func canonicalPrivacyAndDevicePauseApplyBeforeDeliveryAndReadWithdrawsIndependently() async throws {
        let harness = try await NotificationHarness.make()
        try await ready(harness)
        let account = harness.accounts[0]
        let runtime = try #require(await harness.service.runtimes[account.id])
        var settings = NotificationSettings()
        settings.setRule(
            .init(showsPreview: false, readReceipts: false),
            for: .conversation(.init("same")),
            at: .distantPast,
            by: "test"
        )
        let previous = try harness.registry.policy(for: account)
        _ = try harness.registry.setPolicy(settings, for: account, expectedRevision: previous.revision)
        await harness.host.setState(.init(paused: true), account: account.id)
        var message = ReconciliationBackend.message
        message.conversationID = .init("same")
        message.sender = .init("peer")
        try await runtime.appendAndPublish(.messageReceived(message), live: true)
        try await authEventually { await runtime.notificationJob == nil }
        #expect(await harness.host.posts.isEmpty)
        await harness.host.setState(.init(), account: account.id)
        message.id = .init("second-arrival")
        try await runtime.appendAndPublish(.messageReceived(message), live: true)
        try await authEventually { await harness.host.posts.count == 1 }
        let post = try #require(await harness.host.posts.first)
        let payload = try ServiceCodec.decode(HostNotificationPost.self, from: post.payload)
        #expect(!payload.showsPreview && !payload.offersMarkRead)
        try await runtime.appendAndPublish(.readStateChanged(
            conversationID: message.conversationID, lastReadAt: message.createdAt, unread: 0
        ), live: false)
        try await authEventually { await harness.host.frames.contains { $0.operation == "withdraw" } }
        let withdrawal = try #require(await harness.host.frames.first { $0.operation == "withdraw" })
        #expect(withdrawal.account == account.id)
        await harness.service.shutdown()
    }

    @Test func alertsDoNotNeedChatClientsAndAVisibleAccountDoesNotSuppressAnotherAccount() async throws {
        let harness = try await NotificationHarness.make()
        let first = harness.accounts[0]
        let second = harness.accounts[1]
        try await ready(harness)
        await harness.host.setState(.init(conversation: .init("same")), account: first.id)
        try await harness.providers.incoming(first.id)
        try await harness.providers.incoming(second.id)
        try await authEventually { await harness.host.posts.count == 1 }
        #expect(await harness.host.posts.first?.account == second.id)
        let post = try #require(await harness.host.posts.first)
        #expect(try ServiceCodec.decode(HostNotificationPost.self, from: post.payload).members.count <= 16)
        let runtime = try #require(await harness.service.runtimes[first.id])
        #expect(await runtime.subscribers.isEmpty)
        await harness.service.shutdown()
    }

    @Test func chatSubscriptionOverflowAndReplayDoNotLoseOrDuplicateHostNotifications() async throws {
        let harness = try await NotificationHarness.make()
        try await ready(harness)
        let account = harness.accounts[0]
        let runtime = try #require(await harness.service.runtimes[account.id])
        let context = ServiceSessionContext(
            principalID: account.principalID,
            deviceID: .init("client"),
            sessionID: .init("client"),
            accounts: [account.id]
        )
        let first = try await runtime.subscribe(after: nil, attachment: nil, context: context)
        let second = try await runtime.subscribe(after: nil, attachment: nil, context: context)
        try await harness.providers.incoming(account.id, count: 24)
        try await authEventually { await harness.host.posts.count == 24 }
        #expect(await runtime.subscribers.isEmpty)
        let posts = await harness.host.posts
        #expect(Set(posts.map(\.deliveryID)).count == 24)
        let replay = try await runtime.storage.readEvents(after: nil, limit: 256)
        #expect(replay.snapshot != nil)
        #expect(await harness.host.posts.count == 24)
        withExtendedLifetime((first, second)) {}
        await harness.service.shutdown()
    }

    @Test func durableOutboxSurvivesShortChatRetentionAndNeverTurnsKnownHistoryIntoAnArrival() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try SQLiteAccountStorage(account: .init("account"), path: path, retention: 1)
        let device = ServiceDeviceID("device")
        try store.initializeNotifications(for: device)
        let message = ReconciliationBackend.message
        _ = try store.append(.messageReceived(message), live: true)
        _ = try store.append(.messageReceived(message), live: true)
        for _ in 0 ..< 10 {
            _ = try store.append(.connectionStateChanged(.connected), live: false)
        }
        let first = try store.notifications(for: device)
        #expect(first.items.count == 1)
        let reopened = try SQLiteAccountStorage(account: .init("account"), path: path, retention: 1)
        #expect(try reopened.notifications(for: device).items.count == 1)
        try reopened.acknowledgeNotifications(for: device, through: first.checkpoint)
        _ = try reopened.append(.messageReceived(message), live: true)
        #expect(try reopened.notifications(for: device).items.isEmpty)
        try reopened.initializeNotifications(for: .init("new-device"))
        #expect(try reopened.notifications(for: .init("new-device")).items.isEmpty)
    }

    @Test func outboxOverflowResetsExplicitlyInsteadOfReplayingArbitraryHistory() throws {
        let store = try SQLiteAccountStorage(account: .init("account"), path: ":memory:")
        let device = ServiceDeviceID("device")
        try store.initializeNotifications(for: device)
        for index in 0 ..< 520 {
            var message = ReconciliationBackend.message
            message.id = .init("message-\(index)")
            _ = try store.append(.messageReceived(message), live: true)
        }
        let page = try store.notifications(for: device)
        #expect(page.reset && page.items.isEmpty && page.checkpoint == 520)
        try store.acknowledgeNotifications(for: device, through: page.checkpoint)
        #expect(try store.notifications(for: device).items.isEmpty)
    }

    @Test func callHistoryIsStoredButOnlyOrdinaryChatUsesTheMessageNotificationHost() async throws {
        let harness = try await NotificationHarness.make()
        try await ready(harness)
        let account = harness.accounts[0]
        let runtime = try #require(await harness.service.runtimes[account.id])
        for (index, status) in [MessageCallStatus.started, .missed, .ended, .unknown("future")].enumerated() {
            var message = ReconciliationBackend.message
            message.id = .init("call-\(index)"); message.sender = .init("peer")
            message.conversationID = .init("same")
            message.callStatus = status
            try await runtime.appendAndPublish(.messageReceived(message), live: true)
            try await authEventually { await runtime.notificationJob == nil }
            let storage = await runtime.storage
            #expect(try storage.recentHistory(in: message.conversationID, limit: 32)
                .first(where: { $0.id == message.id })?.callStatus == status)
        }
        #expect(await harness.host.posts.isEmpty)
        var ordinary = ReconciliationBackend.message
        ordinary.id = .init("ordinary"); ordinary.sender = .init("peer"); ordinary.text = "Call started"
        ordinary.conversationID = .init("same")
        try await runtime.appendAndPublish(.messageReceived(ordinary), live: true)
        try await authEventually { await harness.host.posts.count == 1 }
        let frame = try #require(await harness.host.posts.first)
        #expect(try ServiceCodec.decode(HostNotificationPost.self, from: frame.payload).message.id == ordinary
            .id)
        await harness.service.shutdown()
    }

    private func ready(_ harness: NotificationHarness) async throws {
        try await authEventually {
            for account in harness.accounts {
                guard let runtime = await harness.service.runtimes[account.id] else { return false }
                let store = await runtime.storage
                guard try store.conversation(.init("same")) != nil else { return false }
            }
            return true
        }
    }
}
