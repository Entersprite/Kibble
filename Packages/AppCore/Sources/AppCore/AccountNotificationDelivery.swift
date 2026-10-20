import ChatAPI
import ChatKit
import Foundation
import Synchronization

public struct AccountNotificationScope: Codable, Hashable, Sendable {
    public let service: ServiceInstanceID
    public let account: ConnectedAccountID
    public let revision: ServiceAccountRevision
    public init(service: ServiceInstanceID, account: ConnectedAccountID, revision: ServiceAccountRevision) {
        self.service = service; self.account = account; self.revision = revision
    }
}

public struct AccountNotificationResponse: Sendable {
    public let scope: AccountNotificationScope
    public let response: NotificationResponse
    public init(scope: AccountNotificationScope, response: NotificationResponse) {
        self.scope = scope; self.response = response
    }
}

/// One process-level native notification endpoint. Account adapters never install
/// an OS delegate or withdraw another account's delivered content.
public protocol AccountNotificationDelivering: Sendable {
    var accountResponses: AsyncStream<AccountNotificationResponse> { get }
    func requestAuthorization() async
    func post(_ notification: MessageNotification, scope: AccountNotificationScope) async
    func withdraw(
        in conversation: Conversation.ID,
        coveredBy position: Date,
        scope: AccountNotificationScope
    ) async
    func withdrawAll(in scope: AccountNotificationScope) async
    func retainNotifications(in scopes: Set<AccountNotificationScope>) async
}

final class ScopedNotificationDelivery: NotificationDelivering, Sendable {
    private struct State { var active = true; var label: String }
    let scope: AccountNotificationScope
    let responses: AsyncStream<NotificationResponse>
    private let continuation: AsyncStream<NotificationResponse>.Continuation
    private let state: Mutex<State>
    private let center: any AccountNotificationDelivering
    private let postsArrivals: Bool
    private let authorize: @Sendable () async -> Void

    init(
        scope: AccountNotificationScope,
        label: String,
        center: any AccountNotificationDelivering,
        postsArrivals: Bool = true,
        authorize: @escaping @Sendable () async -> Void
    ) {
        self.scope = scope; self.center = center; self.authorize = authorize
        self.postsArrivals = postsArrivals
        state = Mutex(State(label: label))
        (responses, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    func retire() {
        state.withLock { $0.active = false }
        continuation.finish()
    }

    var isActive: Bool {
        state.withLock { $0.active }
    }

    func receive(_ response: NotificationResponse) {
        if isActive {
            continuation.yield(response)
        }
    }

    func update(label: String) {
        state.withLock { $0.label = label }
    }

    func requestAuthorization() async {
        await authorize()
    }

    func post(_ notification: MessageNotification) async {
        guard postsArrivals else { return }
        guard let label = state.withLock({ $0.active ? $0.label : nil }) else { return }
        var notification = notification
        notification.subtitle = notification.subtitle.map { $0 + " · " + label } ?? label
        await center.post(notification, scope: scope)
    }

    func withdraw(in conversation: Conversation.ID, coveredBy position: Date) async {
        await center.withdraw(in: conversation, coveredBy: position, scope: scope)
    }

    func withdrawAll() async {
        retire()
        if postsArrivals {
            await center.withdrawAll(in: scope)
        }
    }
}
