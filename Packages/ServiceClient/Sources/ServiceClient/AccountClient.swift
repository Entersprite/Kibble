import ChatAPI
import Foundation

/// Shared account control facade. The host supplies an authenticated transport.
public struct AccountClient: Sendable {
    public let transport: any ServiceTransport

    public init(transport: any ServiceTransport) {
        self.transport = transport
    }

    public func accounts() async throws -> [AccountSummary] {
        try await call(ListAccounts())
    }

    public func pendingLinks() async throws -> [AccountLinkSummary] {
        try await call(ListAccountLinks())
    }

    public func states() async throws -> AsyncThrowingStream<AccountStateSnapshot, any Error> {
        guard let transport = transport as? any ServiceAccountStateTransport
        else { throw ServiceFailure.unsupportedOperation }
        let version = try await transport.negotiate(.current)
        return try await transport.accountStates(ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID(UUID().uuidString),
                deadline: Date().addingTimeInterval(60), version: version
            ), payload: WatchAccounts()
        ))
    }

    public func setEnabled(_ enabled: Bool, account: ConnectedAccountID) async throws -> AccountSummary {
        try await call(SetAccountEnabled(enabled: enabled), account: account)
    }

    public func retryRecovery(_ account: ConnectedAccountID) async throws -> AccountSummary {
        try await call(RetryAccountRecovery(), account: account)
    }

    public func remove(_ account: ConnectedAccountID) async throws {
        _ = try await call(RemoveAccount(), account: account)
    }

    public func beginLink(
        operationID: ServiceOperationID,
        replacing account: ConnectedAccountID? = nil
    ) async throws -> AccountLinkSummary {
        try await call(BeginAccountLink(operationID: operationID, targetAccountID: account))
    }

    public func link(_ id: AccountLinkID) async throws -> AccountLinkSummary {
        try await call(GetAccountLink(linkID: id))
    }

    public func completeLink(_ id: AccountLinkID) async throws -> AccountLinkSummary {
        try await call(CompleteAccountLink(linkID: id))
    }

    public func cancelLink(_ id: AccountLinkID) async throws -> AccountLinkSummary {
        try await call(CancelAccountLink(linkID: id))
    }

    public func call<Payload: ServiceRequestPayload>(
        _ payload: Payload, account: ConnectedAccountID? = nil,
        revision: ServiceAccountRevision? = nil, timeout: TimeInterval = 60
    ) async throws -> Payload.Response {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ServiceFailure.invalidRequest }
        let version = try await transport.negotiate(.current)
        var revision = revision
        if let account, revision == nil {
            guard let summary = try await accounts().first(where: { $0.id == account })
            else { throw ServiceFailure.accountNotFound }
            revision = summary.revision
        }
        let request = try ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID(UUID().uuidString), accountID: account, accountRevision: revision,
            deadline: Date().addingTimeInterval(timeout), version: version
        ), payload: payload)
        return try await transport.exchange(request).value(for: Payload.self)
    }
}
