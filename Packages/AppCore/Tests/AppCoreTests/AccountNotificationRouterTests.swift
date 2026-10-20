import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import AppCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountNotificationRouterTests {
    private let service = ServiceInstanceID("service")

    @Test func backgroundButtonsReachTheServiceWithoutRegisteringAClientDelivery() async throws {
        let center = RoutedNotificationCenter()
        let router = AccountNotificationRouter(service: service, center: center, clientArrivals: false)
        let account = account("one")
        await router.prepare(accounts: [account])
        var handled: [AccountNotificationResponse] = []
        router.onBackgroundResponse = { handled.append($0); return true }
        router.start()
        let response = AccountNotificationResponse(scope: scope(account), response: .mute(.init("same")))
        center.responses.send(response)
        try await wait { handled.count == 1 }
        #expect(handled.first?.scope == response.scope)
        #expect(handled.first?.response == response.response)
        await router.stop()
    }

    @Test func staleAccountSummaryCannotCreateANativeDelivery() async throws {
        let center = RoutedNotificationCenter()
        let router = AccountNotificationRouter(service: service, center: center)
        let current = account("one")
        await router.prepare(accounts: [current])
        let stale = AccountSummary(
            id: current.id,
            selfID: current.selfID,
            label: current.label,
            connection: .connected,
            revision: ServiceAccountRevision("old")
        )
        #expect(throws: ServiceFailure.accountDisabled) { try router.delivery(for: stale) }
        _ = try router.delivery(for: current)
        await router.stop()
    }

    @Test func aDisabledAccountRejectsForeignAndReplacedClicksBeforeOpening() async throws {
        let center = RoutedNotificationCenter()
        let router = AccountNotificationRouter(service: service, center: center)
        let first = account("one", enabled: false)
        let second = account("two", enabled: false)
        await router.prepare(accounts: [first, second])
        var opened: [ConnectedAccountID] = []
        router.onOpenAccount = { opened.append($0) }
        router.start()
        let open = NotificationResponse.open(Conversation.ID("same"))
        center.responses.send(AccountNotificationResponse(
            scope: AccountNotificationScope(
                service: ServiceInstanceID("foreign"),
                account: first.id,
                revision: ServiceAccountRevision("binding")
            ),
            response: open
        ))
        center.responses.send(AccountNotificationResponse(scope: AccountNotificationScope(
            service: service,
            account: first.id,
            revision: ServiceAccountRevision("old")
        ), response: open))
        center.responses.send(AccountNotificationResponse(scope: scope(second), response: open))
        try await wait { opened.last == second.id }
        #expect(opened == [second.id])
        await router.stop()
    }

    @Test func sameEntityIDsDeliverAndWithdrawOnlyTheirAccountAndAuthorizeOnce() async throws {
        let center = RoutedNotificationCenter()
        let router = AccountNotificationRouter(service: service, center: center)
        let accounts = [account("one"), account("two")]
        await router.prepare(accounts: accounts)
        let first = try router.delivery(for: accounts[0])
        let second = try router.delivery(for: accounts[1])
        async let firstAuthorization: Void = first.requestAuthorization()
        async let secondAuthorization: Void = second.requestAuthorization()
        _ = await (firstAuthorization, secondAuthorization)
        #expect(await center.authorizations == 1)
        await first.post(message())
        await second.post(message())
        #expect(await center.posted.count == 2)
        await first.withdraw(in: Conversation.ID("same"), coveredBy: Date.distantFuture)
        #expect(await center.posted.map(\.scope.account) == [accounts[1].id])
        await first.post(message())
        await first.withdrawAll()
        #expect(await center.posted.map(\.scope.account) == [accounts[1].id])
        await first.post(message())
        #expect(await center.posted.count == 1)
        // A retained old environment cannot prevent retrying the same binding.
        let replacement = try router.delivery(for: accounts[0])
        await replacement.post(message())
        #expect(await center.posted.count == 2)
        await router.stop()
    }

    @Test func launchingClickWaitsForRegistrationThenRoutesToItsAccountOnce() async throws {
        let center = RoutedNotificationCenter()
        let router = AccountNotificationRouter(service: service, center: center)
        let account = account("one")
        var opened: [ConnectedAccountID] = []
        router.onOpenAccount = { opened.append($0) }
        center.responses.send(AccountNotificationResponse(
            scope: scope(account),
            response: .open(Conversation.ID("same"))
        ))
        router.start()
        await router.prepare(accounts: [account])
        router.update(accounts: [account])
        let delivery = try router.delivery(for: account)
        let log = RoutedResponseLog()
        let task = Task { for await response in delivery.responses {
            await log.append(response)
        } }
        try await wait { await log.values.count == 1 }
        #expect(opened == [account.id])
        #expect(await log.values == [.open(Conversation.ID("same"))])
        await delivery.withdrawAll()
        await task.value
        await router.stop()
    }

    @Test func foreignRemovedAndReplacedScopesCannotActOnCurrentReplica() async throws {
        let center = RoutedNotificationCenter()
        let router = AccountNotificationRouter(service: service, center: center)
        let account = account("one")
        await router.prepare(accounts: [account])
        let delivery = try router.delivery(for: account)
        let log = RoutedResponseLog()
        let task = Task { for await response in delivery.responses {
            await log.append(response)
        } }
        router.start()
        let action = NotificationResponse.mute(Conversation.ID("same"))
        center.responses.send(AccountNotificationResponse(
            scope: AccountNotificationScope(
                service: ServiceInstanceID("foreign"),
                account: account.id,
                revision: ServiceAccountRevision("binding")
            ),
            response: action
        ))
        center.responses.send(AccountNotificationResponse(scope: AccountNotificationScope(
            service: service,
            account: account.id,
            revision: ServiceAccountRevision("old")
        ), response: action))
        // Positive barrier: this valid response follows the invalid ones in the same stream.
        center.responses.send(AccountNotificationResponse(
            scope: scope(account),
            response: .open(Conversation.ID("same"))
        ))
        try await wait { await log.values.count == 1 }
        #expect(await log.values == [.open(Conversation.ID("same"))])
        router.update(accounts: [])
        await task.value
        await delivery.post(message())
        #expect(await center.posted.isEmpty)
        center.responses.send(AccountNotificationResponse(scope: scope(account), response: action))
        await router.stop()
    }

    @Test func disableRetiresOldStreamButOpenCanSelectDisabledAccountWithoutAnAction() async throws {
        let center = RoutedNotificationCenter()
        let router = AccountNotificationRouter(service: service, center: center)
        let enabled = account("one")
        await router.prepare(accounts: [enabled])
        let delivery = try router.delivery(for: enabled)
        let log = RoutedResponseLog()
        let task = Task { for await response in delivery.responses {
            await log.append(response)
        } }
        var opened: [ConnectedAccountID] = []
        router.onOpenAccount = { opened.append($0) }
        router.start()
        router.update(accounts: [account("one", enabled: false)])
        await task.value
        center.responses.send(AccountNotificationResponse(
            scope: scope(enabled),
            response: .mute(Conversation.ID("same"))
        ))
        center.responses.send(AccountNotificationResponse(
            scope: scope(enabled),
            response: .open(Conversation.ID("same"))
        ))
        try await wait { opened == [enabled.id] }
        #expect(await log.values.isEmpty)
        await router.stop()
    }

    @Test func processResponseSourceSurvivesCancelAndKeepsLaunchingClicksBounded() async {
        let source = AccountNotificationResponses()
        let first = Task { for await _ in source.stream() {} }
        first.cancel(); await first.value
        let account = account("one")
        for index in 0 ..< 100 {
            source.send(AccountNotificationResponse(
                scope: scope(account),
                response: .open(Conversation.ID(String(index)))
            ))
        }
        var iterator = source.stream().makeAsyncIterator()
        let firstRetained = await iterator.next()
        #expect(firstRetained?.response == .open(Conversation.ID("36")))
    }

    private func account(_ id: String, enabled: Bool = true) -> AccountSummary {
        AccountSummary(
            id: ConnectedAccountID(id),
            selfID: Member.ID(id),
            label: id,
            connection: .connected,
            isEnabled: enabled,
            isReady: enabled,
            revision: ServiceAccountRevision("binding")
        )
    }

    private func scope(_ account: AccountSummary) -> AccountNotificationScope {
        AccountNotificationScope(
            service: service,
            account: account.id,
            revision: ServiceAccountRevision("binding")
        )
    }

    private func message() -> MessageNotification {
        MessageNotification(
            id: "same",
            conversationID: Conversation.ID("same"),
            title: "A message",
            subtitle: nil,
            body: "Hello",
            createdAt: Date()
        )
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ServiceFailure.deadlineExceeded
    }
}

private actor RoutedResponseLog {
    private(set) var values: [NotificationResponse] = []
    func append(_ response: NotificationResponse) {
        values.append(response)
    }
}

private actor RoutedNotificationCenter: AccountNotificationDelivering {
    struct Posted: Sendable { let scope: AccountNotificationScope; let message: MessageNotification }
    nonisolated let responses = AccountNotificationResponses()
    nonisolated var accountResponses: AsyncStream<AccountNotificationResponse> {
        responses.stream()
    }

    private(set) var authorizations = 0
    private(set) var posted: [Posted] = []
    func requestAuthorization() {
        authorizations += 1
    }

    func post(_ notification: MessageNotification, scope: AccountNotificationScope) {
        posted.append(Posted(scope: scope, message: notification))
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
