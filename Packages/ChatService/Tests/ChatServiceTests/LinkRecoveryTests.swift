import ChatAPI
import ChatKit
import ChatService
import ChatServiceStorage
import Foundation
import Testing

struct LinkRecoveryTests {
    @Test func committedLinkCleanupCanBeRetriedWithoutCancelingTheNewBinding() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        await harness.custody.configure(identity: record.selfID, discardFailures: 1)
        let begun = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("reauth"),
            targetAccountID: record.id
        ))
        await #expect(throws: ServiceFailure.internalFailure) {
            try await harness.call(CompleteAccountLink(linkID: begun.id))
        }
        let current = try #require(harness.registry.accounts().first)
        #expect(current.credentialGeneration != record.credentialGeneration)
        #expect(try harness.registry.links().first?.phase == "committed")
        let retried = try await harness.call(CancelAccountLink(linkID: begun.id))
        #expect(retried.phase == "completed")
        #expect(try harness.registry.accounts() == [current])
        #expect(await harness.custody.erased == [record.credentialGeneration])
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.service.shutdown()
    }

    @Test func canceledLinkCleanupResumesOnRestartAndCannotPublishAnAccount() async throws {
        let harness = try await LinkHarness.make()
        let begun = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("one")))
        await harness.custody.configure(discardFailures: 1)
        await #expect(throws: ServiceFailure.internalFailure) {
            try await harness.call(CancelAccountLink(linkID: begun.id))
        }
        #expect(try harness.registry.links().first?.phase == "canceling")
        await harness.service.shutdown()
        let restored = ChatService(
            registry: harness.registry,
            storage: SQLiteServiceStorageFactory(directory: harness.directory),
            providers: TestProviders(),
            linkCustody: harness.custody
        )
        try await restored.restore()
        for _ in 0 ..< 1000 {
            if try harness.registry.links().first?.phase == "canceled" {
                break
            }
            await Task.yield()
        }
        #expect(try harness.registry.links().first?.phase == "canceled")
        #expect(try harness.registry.accounts().isEmpty)
        #expect(await restored.activeRuntimeCount == 0)
        await restored.shutdown()
    }

    @Test func competingReconnectIntentsCannotOverwriteACommittedGeneration() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        await harness.custody.configure(identity: record.selfID)
        let first = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("one"),
            targetAccountID: record.id
        ))
        let second = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("two"),
            targetAccountID: record.id
        ))
        _ = try await harness.call(CompleteAccountLink(linkID: first.id))
        let current = try #require(harness.registry.accounts().first)
        await #expect(throws: ServiceFailure.revisionConflict) {
            try await harness.call(CompleteAccountLink(linkID: second.id))
        }
        #expect(try harness.registry.accounts() == [current])
        #expect(await harness.custody.installs == 1)
        await harness.service.shutdown()
    }

    @Test func linkAuthorityComesFromTrustedContextAndHandlesDoNotCrossPrincipalsOrDevices() async throws {
        let harness = try await LinkHarness.make()
        let begun = try await harness.call(BeginAccountLink(operationID: ServiceOperationID("one")))
        let contexts = [
            ServiceSessionContext(
                principalID: harness.context.principalID,
                deviceID: harness.context.deviceID,
                sessionID: ClientSessionID("unprivileged"),
                accounts: []
            ),
            ServiceSessionContext(
                principalID: ServicePrincipalID("foreign"),
                deviceID: harness.context.deviceID,
                sessionID: ClientSessionID("foreign"),
                accounts: [],
                hasAllAccountAccess: true,
                canLinkAccounts: true
            ),
            ServiceSessionContext(
                principalID: harness.context.principalID,
                deviceID: ServiceDeviceID("foreign"),
                sessionID: ClientSessionID("foreign-device"),
                accounts: [],
                hasAllAccountAccess: true,
                canLinkAccounts: true
            )
        ]
        for context in contexts {
            let request = try ServiceRequest(
                header: ServiceRequestHeader(requestID: ServiceRequestID(context.sessionID.rawValue)),
                payload: CompleteAccountLink(linkID: begun.id)
            )
            let response = try await ServiceCodec.decode(
                ServiceResponse.self,
                from: harness.service.handle(ServiceCodec.encode(request), context: context)
            )
            #expect(response.result == .failure(.notAuthorized))
        }
        #expect(await harness.custody.installs == 0)
        await #expect(throws: ServiceFailure.operationConflict) {
            try await harness.call(BeginAccountLink(
                operationID: ServiceOperationID("one"),
                targetAccountID: ConnectedAccountID("changed")
            ))
        }
        await harness.service.shutdown()
    }
}
