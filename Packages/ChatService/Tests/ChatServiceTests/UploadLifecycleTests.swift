import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct UploadLifecycleTests {
    @Test func uploadChunksFinalizeOnceAndAuthorizeOnlyTheOwningConversation() async throws {
        let harness = try await UploadHarness.make()
        let bytes = Data([1, 2, 3, 4])
        let transfer = try await harness.begin(bytes.count)
        #expect(try await harness.begin(bytes.count).id == transfer.id)
        await #expect(throws: ServiceFailure.operationConflict) { try await harness.begin(3) }
        try await harness.write(transfer, bytes: Data([1, 2]))
        try await harness.write(transfer, bytes: Data([1, 2])) // Lost chunk ACK is safe to repeat.
        await #expect(throws: ServiceFailure.operationConflict) {
            try await harness.write(transfer, bytes: Data([9, 9]))
        }
        let finalize = FinalizeUploadTransfer(transferID: transfer.id, operationID: .init("finalize"))
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await harness.call(finalize, account: harness.first)
        }
        try await harness.write(transfer, bytes: Data([3, 4]), offset: 2)
        let attachment = try await harness.call(finalize, account: harness.first)
        #expect(try await harness.call(finalize, account: harness.first) == attachment)
        let provider = try #require(await harness.providers.backend(harness.first.id))
        #expect(await provider.uploaded == [bytes])
        let file = try #require(await provider.files.first)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let other = SendCommand(operationID: .init("other-send"), command: .sendMessage(
            conversationID: .init("other"), threadID: nil, text: "file", localID: "other-send",
            attachments: [attachment], mentions: []
        ))
        await #expect(throws: ServiceFailure.notAuthorized) { try await harness.call(
            other,
            account: harness.first
        ) }
        let send = SendCommand(operationID: .init("send"), command: .sendMessage(
            conversationID: .init("conversation"), threadID: nil, text: "file", localID: "send",
            attachments: [attachment], mentions: []
        ))
        #expect(try await harness.call(send, account: harness.first).state == "succeeded")
        #expect(await provider.sends.count == 1)
        await harness.service.shutdown()
    }

    @Test func accountSessionMembershipQuotaAndCancellationAreChecked() async throws {
        let harness = try await UploadHarness.make(limits: .init(
            maximumFileBytes: 4, maximumAccountBytes: 4, maximumAccountTransfers: 1
        ))
        let transfer = try await harness.begin(4)
        await #expect(throws: ServiceFailure.overloaded) { try await harness.begin(1, operation: "extra") }
        await #expect(throws: ServiceFailure.invalidRequest) { try await harness.begin(5, operation: "large")
        }
        await #expect(throws: ServiceFailure.transferExpired) {
            try await harness.write(transfer, bytes: Data([1]), account: harness.second)
        }
        let foreign = InProcessChatTransport(endpoint: harness.service, context: ServiceSessionContext(
            principalID: harness.first.principalID, deviceID: .init("other-device"),
            sessionID: .init("other-session"),
            accounts: [harness.first.id]
        ))
        _ = try await foreign.negotiate(.current)
        let request = try harness.request(
            WriteTransferChunk(transferID: transfer.id, offset: 0, count: 1),
            account: harness.first
        )
        let reply = try await foreign.exchangeBinary(request, body: Data([1]))
        #expect(throws: ServiceFailure.notAuthorized) {
            try reply.response.value(for: WriteTransferChunk.self)
        }
        _ = try await harness.call(CancelTransfer(transferID: transfer.id), account: harness.first)
        _ = try await harness.call(CancelTransfer(transferID: transfer.id), account: harness.first)
        await #expect(throws: ServiceFailure.transferExpired) { try await harness.write(
            transfer,
            bytes: Data([1])
        ) }
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await provider.setMember(false)
        await #expect(throws: ServiceFailure.notAuthorized) { try await harness.begin(
            4,
            operation: "not-member"
        ) }
        await provider.setMember(true)
        let replacement = try await harness.begin(4, operation: "replacement")
        #expect(replacement.id != transfer.id)
        await harness.service.shutdown()
    }

    @Test func disableDrainsHeldProviderBeforeErasingItsSpoolAndFencesLateWrites() async throws {
        let harness = try await UploadHarness.make()
        let transfer = try await harness.begin(4)
        try await harness.write(transfer, bytes: Data([1, 2, 3, 4]))
        let provider = try #require(await harness.providers.backend(harness.first.id))
        await provider.holdUploads()
        let finalize = Task { try await harness.call(FinalizeUploadTransfer(
            transferID: transfer.id, operationID: .init("held")
        ), account: harness.first) }
        let entered = await wait { await provider.held }
        #expect(entered)
        let file = await provider.files.first
        let disable = Task {
            try await harness.call(SetAccountEnabled(enabled: false), account: harness.first)
        }
        let disabling = await wait {
            await (try? harness.call(ListAccounts()).first { $0.id == harness.first.id }?.isEnabled) == false
        }
        #expect(disabling)
        if let file {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        await provider.release()
        _ = await finalize.result
        _ = try await disable.value
        #expect(await provider.acknowledged)
        #expect(try await harness.call(GetOperation(operationID: .init("held")), account: harness.first)
            .state == "unknown")
        if let file {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
        await #expect(throws: ServiceFailure.accountDisabled) { try await harness.write(
            transfer,
            bytes: Data([1])
        ) }
        _ = try await harness.call(SetAccountEnabled(enabled: true), account: harness.first)
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        let references = try #require(await runtime.storage as? any ServiceUploadReferences)
        #expect(try references
            .uploadedAttachment("held-upload", in: .init("conversation"), at: Date()) == nil)
        await #expect(throws: ServiceFailure.transferExpired) { try await harness.write(
            transfer,
            bytes: Data([1])
        ) }
        await harness.service.shutdown()
    }

    private func wait(_ condition: () async -> Bool) async -> Bool {
        for _ in 0 ..< 2000 {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}
