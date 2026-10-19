import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

struct BindingTests {
    @Test func reconnectFencesOldRequestsAndSubscriptionsWithANewPersistedRevision() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        await harness.custody.configure(identity: record.selfID)
        let request = try ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID("captured"), accountID: record.id,
            accountRevision: record.currentRevision
        ), payload: ReadEvents(cursor: nil, limit: 1))
        let link = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("reauth"),
            targetAccountID: record.id
        ))
        _ = try await harness.call(CompleteAccountLink(linkID: link.id))
        let saved = try #require(harness.registry.accounts().first)
        #expect(saved.currentRevision != record.currentRevision)
        let response = try await ServiceCodec.decode(
            ServiceResponse.self,
            from: harness.service.handle(ServiceCodec.encode(request), context: harness.context)
        )
        #expect(response.result == .failure(.staleAccount))
        await #expect(throws: ServiceFailure.staleAccount) {
            try await harness.service.events(ServiceCodec.encode(request), context: harness.context)
        }
        let current = try await harness.call(ReadEvents(cursor: nil, limit: 1), account: record.id)
        #expect(current.snapshot != nil)
        let reopened = try SQLiteAccountRegistry(path: harness.directory
            .appendingPathComponent("registry.sqlite").path)
        #expect(try reopened.accounts().first?.currentRevision == saved.currentRevision)
        await harness.service.shutdown()
    }

    @Test func missingRevisionCannotRemoveAnAuthorizedAccount() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        let request = try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID("missing"), accountID: record.id),
            payload: RemoveAccount()
        )
        let response = try await ServiceCodec.decode(
            ServiceResponse.self,
            from: harness.service.handle(ServiceCodec.encode(request), context: harness.context)
        )
        #expect(response.result == .failure(.staleAccount))
        #expect(try harness.registry.accounts() == [record])
        #expect(await harness.providers.forgotten.isEmpty)
        await harness.service.shutdown()
    }

    @Test func disableEnableKeepsTheSameBindingAndAnotherAccountsRevisionIsRefused() async throws {
        let harness = try await ServiceHarness.make()
        _ = try await harness.call(SetAccountEnabled(enabled: false), account: harness.first.id)
        _ = try await harness.call(SetAccountEnabled(enabled: true), account: harness.first.id)
        let accounts = try await harness.call(ListAccounts())
        #expect(accounts.first { $0.id == harness.first.id }?.revision == harness.first.currentRevision)
        let request = try ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID("foreign-binding"), accountID: harness.first.id,
            accountRevision: harness.second.currentRevision
        ), payload: ReadEvents(cursor: nil, limit: 1))
        let response = try await harness.transport.exchange(request)
        #expect(response.result == .failure(.staleAccount))
        await harness.service.shutdown()
    }

    @Test func legacyRegistryRecordHasAStableInitialRevisionUntilReplacement() throws {
        let record = LinkHarness.existing()
        guard case var .object(json) = try ServiceCodec.value(record)
        else { throw ServiceFailure.invalidResponse }
        json["revision"] = nil
        let legacy = try ServiceCodec.decode(AccountRecord.self, from: .object(json))
        #expect(legacy.currentRevision == ServiceAccountRevision("initial:existing"))
        let restored = try ServiceCodec.decode(AccountRecord.self, from: ServiceCodec.encode(legacy))
        #expect(restored.currentRevision == legacy.currentRevision)
    }
}
