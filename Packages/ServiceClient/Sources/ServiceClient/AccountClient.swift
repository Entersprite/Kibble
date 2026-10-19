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

    public func setEnabled(_ enabled: Bool, account: ConnectedAccountID) async throws -> AccountSummary {
        try await call(SetAccountEnabled(enabled: enabled), account: account)
    }

    public func remove(_ account: ConnectedAccountID) async throws {
        _ = try await call(RemoveAccount(), account: account)
    }

    public func call<Payload: ServiceRequestPayload>(
        _ payload: Payload, account: ConnectedAccountID? = nil
    ) async throws -> Payload.Response {
        let version = try await transport.negotiate(.current)
        let request = try ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID(UUID().uuidString), accountID: account,
            deadline: Date().addingTimeInterval(60), version: version
        ), payload: payload)
        return try await transport.exchange(request).value(for: Payload.self)
    }
}
