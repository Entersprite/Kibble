import ChatAPI
import ChatKit
import Foundation

extension ChatService {
    func listAccounts(_ context: ServiceSessionContext) async throws -> JSONValue {
        try ServiceCodec.value(accountSummaries(context))
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
