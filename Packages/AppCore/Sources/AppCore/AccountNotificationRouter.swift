import ChatAPI
import ChatKit
import Foundation

/// Owns one native response consumer and dispatches only current bindings.
/// Account teardown drains its coordinator's posts before scoped withdrawal.
@MainActor
public final class AccountNotificationRouter {
    private let service: ServiceInstanceID
    private let center: any AccountNotificationDelivering
    private let clientArrivals: Bool
    private var accounts: [ConnectedAccountID: AccountSummary] = [:]
    private var deliveries: [AccountNotificationScope: WeakNotificationDelivery] = [:]
    private var pending: [AccountNotificationResponse] = []
    private var prepared = false
    private var stopped = false
    private var task: Task<Void, Never>?
    private var authorization: Task<Void, Never>?
    public var onOpenAccount: ((ConnectedAccountID) -> Void)?
    public var onBackgroundResponse: ((AccountNotificationResponse) -> Bool)?

    public init(
        service: ServiceInstanceID,
        center: any AccountNotificationDelivering,
        clientArrivals: Bool = true
    ) {
        self.service = service; self.center = center
        self.clientArrivals = clientArrivals
    }

    public func start() {
        guard task == nil, !stopped else { return }
        task = Task { [weak self, center] in
            for await response in center.accountResponses {
                guard !Task.isCancelled else { return }
                self?.receive(response)
            }
        }
    }

    public func prepare(accounts: [AccountSummary]) async {
        update(accounts: accounts)
        await center.retainNotifications(in: Set(accounts.compactMap { account in
            guard canDeliver(account), let revision = account.revision else { return nil }
            return AccountNotificationScope(service: service, account: account.id, revision: revision)
        }))
    }

    public func update(accounts: [AccountSummary]) {
        guard !stopped else { return }
        self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for (scope, weak) in deliveries {
            if weak.value == nil {
                deliveries[scope] = nil
            } else if !isCurrent(scope, delivering: true) {
                weak.value?.retire()
                deliveries[scope] = nil
            } else if let account = self.accounts[scope.account] {
                weak.value?.update(label: account.label)
            }
        }
        let held = pending
        pending = []
        prepared = true
        for response in held {
            receive(response)
        }
    }

    public func delivery(for account: AccountSummary) throws -> any NotificationDelivering {
        guard !stopped, let revision = account.revision else { throw ServiceFailure.staleAccount }
        let scope = AccountNotificationScope(service: service, account: account.id, revision: revision)
        guard isCurrent(scope, delivering: true) else { throw ServiceFailure.accountDisabled }
        guard deliveries[scope]?.value?.isActive != true else { throw ServiceFailure.operationConflict }
        let delivery = ScopedNotificationDelivery(
            scope: scope,
            label: account.label,
            center: center, postsArrivals: clientArrivals
        ) { [weak self] in
            await self?.requestAuthorization()
        }
        deliveries[scope] = WeakNotificationDelivery(delivery)
        let held = pending.filter { $0.scope == scope }
        pending.removeAll { $0.scope == scope }
        for response in held {
            if response.response.bringsWindowForward {
                onOpenAccount?(scope.account)
            }
            delivery.receive(response.response)
        }
        return delivery
    }

    public func stop() async {
        stopped = true
        let task = task
        self.task = nil
        task?.cancel()
        await task?.value
        deliveries.values.forEach { $0.value?.retire() }
        deliveries = [:]; pending = []; accounts = [:]
    }

    public func withdraw(for account: AccountSummary) async {
        guard let revision = account.revision else { return }
        await center.withdrawAll(in: AccountNotificationScope(
            service: service,
            account: account.id,
            revision: revision
        ))
    }

    private func requestAuthorization() async {
        guard !stopped, clientArrivals else { return }
        if authorization == nil {
            authorization = Task { [center] in await center.requestAuthorization() }
        }
        await authorization?.value
    }

    private func receive(_ response: AccountNotificationResponse) {
        guard !stopped else { return }
        guard prepared else { hold(response); return }
        guard isCurrent(response.scope, delivering: false) else { return }
        guard isCurrent(response.scope, delivering: true) else {
            if response.response.bringsWindowForward {
                onOpenAccount?(response.scope.account)
            }
            return
        }
        if onBackgroundResponse?(response) == true {
            return
        }
        if let delivery = deliveries[response.scope]?.value, delivery.isActive {
            if response.response.bringsWindowForward {
                onOpenAccount?(response.scope.account)
            }
            delivery.receive(response.response)
        } else {
            hold(response)
        }
    }

    private func hold(_ response: AccountNotificationResponse) {
        if pending.count == 64 {
            pending.removeFirst()
        }
        pending.append(response)
    }

    private func isCurrent(_ scope: AccountNotificationScope, delivering: Bool) -> Bool {
        guard scope.service == service, let account = accounts[scope.account],
              account.revision == scope.revision, !account.isRemoving else { return false }
        return !delivering || canDeliver(account)
    }

    private func canDeliver(_ account: AccountSummary) -> Bool {
        account.isEnabled && account.authenticationState == nil
    }
}

private final class WeakNotificationDelivery {
    weak var value: ScopedNotificationDelivery?
    init(_ value: ScopedNotificationDelivery) {
        self.value = value
    }
}
