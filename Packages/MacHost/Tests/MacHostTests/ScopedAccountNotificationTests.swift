import AppCore
import ChatAPI
import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import MacHost

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ScopedAccountNotificationTests {
    @Test func aHeldNativePostDrainsBeforeAccountWithdrawalWithoutBlockingAnotherAccount() async throws {
        let center = NativeAccountNotificationFixture()
        let host = SystemAccountFixtureHost(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            notifications: center
        )
        await host.start()
        let workspace = try #require(host.workspace)
        try await ready(workspace)
        let first = try #require(workspace.accounts.first)
        let second = try #require(workspace.accounts.last)
        await center.block(first.id)
        do {
            await host.simulateMessage(first.id.rawValue, text: "Held first notification")
            try await wait { await center.heldCount == 1 }
            await host.setEnabled(false, account: first.id.rawValue)
            await host.simulateMessage(second.id.rawValue, text: "Independent second notification")
            try await wait { await center.posted.contains { $0.scope.account == second.id } }
            await center.release()
            try await wait {
                let posted = await center.posted
                let completed = await center.history.contains { $0.scope.account == first.id }
                return completed && posted.count == 1 && posted.first?.scope.account == second.id
            }
            await host.stop()
        } catch {
            await center.release()
            await host.stop()
            throw error
        }
    }

    @Test func backgroundAccountsNotifyAndClicksSelectTheOwnerWhileDisableWithdrawsOnlyItsContent(
    ) async throws {
        let center = NativeAccountNotificationFixture()
        let host = SystemAccountFixtureHost(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            notifications: center
        )
        await host.start()
        let workspace = try #require(host.workspace)
        try await ready(workspace)
        #expect(host.deviceNotificationPause?.isActive == false)
        #expect(host.deviceNotificationPause?.lastError == nil)
        let first = try #require(workspace.accounts.first)
        let second = try #require(workspace.accounts.last)
        host.selectAccount(first.id.rawValue)
        await host.simulateMessage(first.id.rawValue, text: "First account background message")
        await host.simulateMessage(second.id.rawValue, text: "Second account background message")
        try await wait { await center.posted.count == 2 }
        let notifications = await center.posted
        #expect(Set(notifications.map(\.scope.account)) == [first.id, second.id])
        #expect(await center.authorizations == 1)
        let secondNotification = try #require(notifications.first { $0.scope.account == second.id })
        center.responses.send(AccountNotificationResponse(
            scope: secondNotification.scope,
            response: .open(Acme.priceEngine)
        ))
        try await wait { workspace.selectedID == second.id && workspace.windowRequests > 0 }
        try await wait { workspace.selectedEnvironment?.sceneState.selected == Acme.priceEngine }
        await host.setEnabled(false, account: first.id.rawValue)
        try await wait {
            let remaining = await center.posted
            return workspace.environment(for: first.id) == nil && remaining.count == 1 && remaining.first?
                .scope.account == second.id
        }
        await host.stop()
        #expect(await center.posted.isEmpty)
    }

    @Test func devicePauseAppliesToBothAccountsAndSurvivesRelaunch() async throws {
        let center = NativeAccountNotificationFixture()
        let host = SystemAccountFixtureHost(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            notifications: center
        )
        await host.start()
        let workspace = try #require(host.workspace)
        try await ready(workspace)
        let first = try #require(workspace.accounts.first)
        let second = try #require(workspace.accounts.last)
        let firstEnvironment = try #require(workspace.environment(for: first.id))
        let secondEnvironment = try #require(workspace.environment(for: second.id))
        #expect(firstEnvironment.deviceNotificationPause === secondEnvironment.deviceNotificationPause)
        firstEnvironment.pauseNotifications(.untilResumed)
        #expect(secondEnvironment.pauseStatus != nil)
        firstEnvironment.actions.select(Acme.priceEngine)
        secondEnvironment.actions.select(Acme.priceEngine)
        await host.simulateMessage(first.id.rawValue, text: "Paused first message")
        await host.simulateMessage(second.id.rawValue, text: "Paused second message")
        try await wait {
            firstEnvironment.sceneState.messages.contains { $0.text == "Paused first message" } &&
                secondEnvironment.sceneState.messages.contains { $0.text == "Paused second message" }
        }
        // An absence assertion, with arrival positively established above.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await center.posted.isEmpty)
        secondEnvironment.resumeNotifications()
        await host.simulateMessage(first.id.rawValue, text: "Resumed first message")
        await host.simulateMessage(second.id.rawValue, text: "Resumed second message")
        try await wait { await center.posted.count == 2 }
        #expect(await center.posted.allSatisfy { $0.message.body.hasPrefix("Resumed") })
        firstEnvironment.pauseNotifications(.untilResumed)
        await host.stop()
        await host.start()
        let restarted = try #require(host.workspace)
        try await ready(restarted)
        #expect(host.deviceNotificationPause?.isActive == true)
        #expect(restarted.accounts.allSatisfy { restarted.environment(for: $0.id)?.pauseStatus != nil })
        host.deviceNotificationPause?.resume()
        await host.simulateMessage(second.id.rawValue, text: "Message after host restart")
        try await wait { await center.posted.count == 1 }
        let delivered = try #require(await center.posted.first)
        center.responses.send(AccountNotificationResponse(
            scope: delivered.scope,
            response: .open(Acme.priceEngine)
        ))
        try await wait { restarted.selectedID == second.id && restarted.windowRequests > 0 }
        await host.stop()
    }

    @Test func nativeIdentifiersAndReadWithdrawalIncludeServiceAccountAndBinding() throws {
        let first = AccountNotificationScope(
            service: ServiceInstanceID("service"),
            account: ConnectedAccountID("one"),
            revision: ServiceAccountRevision("binding")
        )
        let second = AccountNotificationScope(
            service: first.service,
            account: ConnectedAccountID("two"),
            revision: first.revision
        )
        let replacement = AccountNotificationScope(
            service: first.service,
            account: first.account,
            revision: ServiceAccountRevision("next")
        )
        let message = MessageNotification(
            id: "same",
            conversationID: Conversation.ID("same"),
            title: "Message",
            subtitle: nil,
            body: "Hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isReply: true
        )
        let content = try UserNotificationDelivery.scopedContent(message, scope: first)
        let other = try UserNotificationDelivery.scopedContent(message, scope: second)
        #expect(content.threadIdentifier != other.threadIdentifier)
        #expect(UserNotificationDelivery.scopedIdentifier(message.id, scope: first) !=
            UserNotificationDelivery.scopedIdentifier(message.id, scope: replacement))
        #expect(UserNotificationDelivery.accountScope(in: content.userInfo) == first)
        #expect(UserNotificationDelivery.reply(in: content.userInfo) == Message.ID(message.id))
        let delivered = [content, other].enumerated().map {
            UserNotificationDelivery.Delivered(
                identifier: String($0.offset),
                thread: $0.element.threadIdentifier,
                userInfo: $0.element.userInfo
            )
        }
        #expect(UserNotificationDelivery.covered(
            delivered,
            in: content.threadIdentifier,
            upTo: UserNotificationDelivery.micros(message.createdAt)
        ) ==
            ["0"])
        #expect(UserNotificationDelivery
            .accountScope(in: [UserNotificationDelivery.accountScopeKey: Data("broken".utf8)]) == nil)
    }

    private func ready(_ workspace: AccountWorkspace) async throws {
        try await wait {
            workspace.accounts.count == 2 && workspace.accounts.allSatisfy {
                workspace.environment(for: $0.id)?.isPolicyReady == true &&
                    workspace.environment(for: $0.id)?.sceneState.connection == .connected
            }
        }
    }

    private func wait(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Native scoped notification condition did not arrive", sourceLocation: sourceLocation)
        throw ServiceFailure.deadlineExceeded
    }
}

private actor NativeAccountNotificationFixture: AccountNotificationDelivering {
    struct Posted: Sendable { let scope: AccountNotificationScope; let message: MessageNotification }
    nonisolated let responses = AccountNotificationResponses()
    nonisolated var accountResponses: AsyncStream<AccountNotificationResponse> {
        responses.stream()
    }

    private(set) var posted: [Posted] = []
    private(set) var authorizations = 0
    private(set) var history: [Posted] = []
    private var blocked: ConnectedAccountID?
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int {
        held.count
    }

    func block(_ account: ConnectedAccountID) {
        blocked = account
    }

    func release() {
        blocked = nil
        let held = held
        self.held = []
        held.forEach { $0.resume() }
    }

    func requestAuthorization() {
        authorizations += 1
    }

    func post(_ notification: MessageNotification, scope: AccountNotificationScope) async {
        if blocked == scope.account {
            await withCheckedContinuation { held.append($0) }
        }
        let value = Posted(scope: scope, message: notification)
        posted.append(value)
        history.append(value)
    }

    func withdraw(
        in conversation: Conversation.ID,
        coveredBy position: Date,
        scope: AccountNotificationScope
    ) {
        posted
            .removeAll {
                $0.scope == scope && $0.message.conversationID == conversation && $0.message
                    .createdAt <= position
            }
    }

    func withdrawAll(in scope: AccountNotificationScope) {
        posted.removeAll { $0.scope == scope }
    }

    func retainNotifications(in scopes: Set<AccountNotificationScope>) {
        posted.removeAll { !scopes.contains($0.scope) }
    }
}
