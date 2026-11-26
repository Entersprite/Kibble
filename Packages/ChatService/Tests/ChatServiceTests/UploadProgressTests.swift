import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct UploadProgressTests {
    @Test func statusIsMonotonicBoundedAndOwnedByTheOriginalAccountAndSession() async throws {
        let harness = try await UploadHarness.make()
        let transfer = try await harness.begin(4)
        let query = GetUploadTransfer(transferID: transfer.id)
        let initial = try await harness.call(query, account: harness.first)
        #expect(initial.transfer == transfer)
        #expect(initial.phase == "receiving" && initial.stagedBytes == 0 && initial.providerBytesSent == 0)
        try await harness.write(transfer, bytes: Data([1, 2, 3, 4]))
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await provider.holdUploads()
        let finalize = Task { try await harness.call(FinalizeUploadTransfer(
            transferID: transfer.id, operationID: .init("progress-finalize")
        ), account: harness.first) }
        try await authEventually { await provider.held }
        for count in [3, 1, Int.max, -1] {
            await provider.reportUploadProgress(count)
        }
        let status = try await harness.call(query, account: harness.first)
        #expect(status.phase == "uploading" && status.stagedBytes == 4 && status.providerBytesSent == 3)
        await #expect(throws: ServiceFailure.transferExpired) {
            try await harness.call(query, account: harness.second)
        }
        for (device, session) in [("device", "foreign"), ("foreign", "session")] {
            let foreign = InProcessChatTransport(endpoint: harness.service, context: ServiceSessionContext(
                principalID: harness.first.principalID, deviceID: .init(device),
                sessionID: .init(session), accounts: [harness.first.id]
            ))
            _ = try await foreign.negotiate(.current)
            let reply = try await foreign.exchange(harness.request(query, account: harness.first))
            #expect(throws: ServiceFailure.notAuthorized) { try reply.value(for: GetUploadTransfer.self) }
        }
        await provider.release()
        _ = try await finalize.value
        await provider.reportUploadProgress(4)
        await #expect(throws: ServiceFailure.transferExpired) {
            try await harness.call(query, account: harness.first)
        }
        #expect(try await harness.call(
            GetOperation(operationID: .init("progress-finalize")),
            account: harness.first
        ).state == "succeeded")
        await harness.service.shutdown()
    }

    @Test func cancellationRetiresProgressBeforeANoncooperativeProviderAnswers() async throws {
        let harness = try await UploadHarness.make()
        let transfer = try await harness.begin(4)
        try await harness.write(transfer, bytes: Data([1, 2, 3, 4]))
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await provider.holdUploads()
        let finalizing = Task { try await harness.call(FinalizeUploadTransfer(
            transferID: transfer.id, operationID: .init("canceled-progress")
        ), account: harness.first) }
        try await authEventually { await provider.held }
        let canceling = Task { try await harness.call(
            CancelTransfer(transferID: transfer.id),
            account: harness.first
        ) }
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        try await authEventually { await runtime.uploads[transfer.id]?.retired == true }
        await provider.reportUploadProgress(4)
        await #expect(throws: ServiceFailure.transferExpired) {
            try await harness.call(GetUploadTransfer(transferID: transfer.id), account: harness.first)
        }
        await provider.release()
        _ = await finalizing.result
        _ = try await canceling.value
        #expect(try await harness.call(
            GetOperation(operationID: .init("canceled-progress")),
            account: harness.first
        ).state == "unknown")
        await harness.service.shutdown()
    }
}
