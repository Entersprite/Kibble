import ChatAPI
import ChatKit
import Foundation

extension ChatService {
    func serviceInfo(_ request: ServiceRequest) throws -> JSONValue {
        _ = try request.decodePayload(GetServiceInfo.self)
        return try ServiceCodec.value(ServiceInfo(instanceID: instanceID))
    }

    func listAccounts(_ context: ServiceSessionContext) async throws -> JSONValue {
        try ServiceCodec.value(accountSummaries(context))
    }

    func accountPolicy(_ request: ServiceRequest, record: AccountRecord) async throws -> JSONValue {
        if request.operation == GetAccountPolicy.operation {
            _ = try request.decodePayload(GetAccountPolicy.self)
            let policy = try policies.policy(for: record)
            policyRevisionChanged(policy.revision, account: record.id)
            return try ServiceCodec.value(policy)
        }
        let payload = try request.decodePayload(SetAccountPolicy.self)
        let policy = try policies.setPolicy(
            payload.settings,
            for: record,
            expectedRevision: payload.expectedRevision
        )
        policyRevisionChanged(policy.revision, account: record.id)
        try await runtimes[record.id]?.clientPolicyChanged()
        return try ServiceCodec.value(policy)
    }

    private func policyRevisionChanged(_ revision: String, account: ConnectedAccountID) {
        guard policyRevisions[account] != revision else { return }
        policyRevisions[account] = revision
        accountStateChanged()
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
