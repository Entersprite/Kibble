import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import SyncEngine
@testable import AppCore

actor WorkspaceTransport: ServiceAccountStateTransport {
    var state: AccountStateSnapshot
    private var subscribers: [UUID: AsyncThrowingStream<AccountStateSnapshot, any Error>.Continuation] = [:]
    private(set) var beginnings = 0

    init(_ accounts: [AccountSummary]) {
        state = .init(accounts: accounts, pendingLinks: [])
    }

    func negotiate(_ version: ServiceAPIVersion) -> ServiceAPIVersion {
        version
    }

    func publish(_ accounts: [AccountSummary]) {
        state = .init(accounts: accounts, pendingLinks: [])
        for subscriber in subscribers.values {
            subscriber.yield(state)
        }
    }

    func accountStates(_ request: ServiceRequest) throws
        -> AsyncThrowingStream<AccountStateSnapshot, any Error> {
        _ = try request.decodePayload(WatchAccounts.self)
        let id = UUID()
        let (stream, sink) = AsyncThrowingStream<AccountStateSnapshot, any Error>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = sink
        sink.yield(state)
        sink.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }

    func exchange(_ request: ServiceRequest) throws -> ServiceResponse {
        let value: JSONValue
        switch request.operation {
        case ListAccounts.operation: value = try ServiceCodec.value(state.accounts)
        case BeginAccountLink.operation:
            beginnings += 1
            let payload = try request.decodePayload(BeginAccountLink.self)
            value = try ServiceCodec.value(AccountLinkSummary(
                id: AccountLinkID("capture"), accountID: payload.targetAccountID ?? ConnectedAccountID("new"),
                phase: "pendingCapture"
            ))
        default: return ServiceResponse(replyingTo: request, result: .failure(.unsupportedOperation))
        }
        return ServiceResponse(replyingTo: request, result: .success(value))
    }
}

@MainActor
final class WorkspaceHost: AccountSessionHost {
    private(set) var prepared = false
    private(set) var creations: [ConnectedAccountID: Int] = [:]
    private(set) var services: [ConnectedAccountID: FakeLaunchServices] = [:]
    private(set) var erased: Set<ConnectedAccountID> = []
    private(set) var entered: Set<ConnectedAccountID> = []
    var eraseFailure = false
    var hold: ConnectedAccountID?
    private var stores: [ConnectedAccountID: ChatStore] = [:]
    private var waiters: [ConnectedAccountID: CheckedContinuation<Void, Never>] = [:]

    func prepareForAccounts(_ accounts: [AccountSummary]) {
        prepared = true
    }

    func makeEnvironment(for account: AccountSummary) async throws -> AppEnvironment {
        creations[account.id, default: 0] += 1
        entered.insert(account.id)
        if hold == account.id {
            await withCheckedContinuation { waiters[account.id] = $0 }
        }
        let store: ChatStore
        if let previous = stores[account.id] {
            store = previous
        } else {
            store = try ChatStore.inMemory()
            try store.apply([.replaceConversations([Conversation(
                id: Conversation.ID("same"),
                kind: .space,
                title: account.label
            )])])
            stores[account.id] = store
        }
        let services = try FakeLaunchServices(
            arguments: LaunchArguments(backend: .fixture),
            existingStore: store
        )
        self.services[account.id] = services
        return AppEnvironment(services: services)
    }

    func release(_ account: ConnectedAccountID) {
        waiters.removeValue(forKey: account)?.resume()
    }

    func eraseReplica(for account: AccountSummary) throws {
        if eraseFailure {
            throw ServiceFailure.internalFailure
        }
        try stores[account.id]?.erase()
        erased.insert(account.id)
    }
}

func workspaceAccount(
    _ id: String, revision: String = "binding", enabled: Bool = true, authentication: String? = nil,
    ready: Bool = true
) -> AccountSummary {
    AccountSummary(
        id: ConnectedAccountID(id), selfID: Member.ID("self-\(id)"), label: id,
        connection: .connected, isEnabled: enabled, isReady: ready,
        capabilities: Capabilities(canSendMessages: true), revision: ServiceAccountRevision(revision),
        authenticationState: authentication
    )
}

@MainActor
func workspaceEventually(_ condition: @MainActor () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ServiceFailure.deadlineExceeded
}
