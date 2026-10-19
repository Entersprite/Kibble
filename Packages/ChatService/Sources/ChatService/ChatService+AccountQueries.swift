import ChatAPI
import ChatKit
import Foundation

extension ChatService {
    func listAccounts(_ context: ServiceSessionContext) async throws -> JSONValue {
        var accounts: [AccountSummary] = []
        for record in records.values.sorted(by: { $0.id.rawValue < $1.id.rawValue })
            where record.principalID == context.principalID && context
            .allowsAccount(record.id) {
            let runtime = runtimes[record.id]
            await accounts.append(AccountSummary(
                id: record.id, selfID: record.selfID, label: record.label,
                connection: runtime?.connection ?? .disconnected(reason: nil, issue: nil),
                isEnabled: record.isEnabled, isRemoving: record.isRemoving,
                capabilities: runtime?.capabilities ?? .init(), revision: record.currentRevision,
                authenticationState: record.authenticationState
            ))
        }
        return try ServiceCodec.value(accounts)
    }

    func accountPolicy(_ request: ServiceRequest, record: AccountRecord) throws -> JSONValue {
        if request.operation == GetAccountPolicy.operation {
            _ = try request.decodePayload(GetAccountPolicy.self)
            return try ServiceCodec.value(policies.policy(for: record))
        }
        let payload = try request.decodePayload(SetAccountPolicy.self)
        return try ServiceCodec.value(policies.setPolicy(
            payload.settings,
            for: record,
            expectedRevision: payload.expectedRevision
        ))
    }

    func readDisabledAccount(
        _ request: ServiceRequest,
        account: ConnectedAccountID
    ) throws -> JSONValue {
        let payload = try request.decodePayload(GetOperation.self)
        guard let result = try storage.open(account).operation(payload.operationID)
        else { throw ServiceFailure.operationUnknown }
        return try ServiceCodec.value(result)
    }

    func accountOperationStatus(_ request: ServiceRequest, record: AccountRecord) async throws -> JSONValue {
        guard !changing.contains(record.id) else { throw ServiceFailure.overloaded }
        if let runtime = runtimes[record.id] {
            return try await runtime.handle(request)
        }
        return try readDisabledAccount(request, account: record.id)
    }
}
