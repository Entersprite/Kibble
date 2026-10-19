import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import Synchronization
import Testing
@testable import ChatService
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
struct UploadClientTests {
    @Test func clientFileStreamsAsBoundedChunksAndLostFinalizeReplyIsReconciledWithoutResending(
    ) async throws {
        let harness = try await ClientHarness.make(uploads: true)
        let tap = UploadTransportTap(base: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        await tap.dropFinalizationReply()
        let backend = ServiceBackend(account: harness.first, transport: tap)
        let bytes = Data((0 ..< 140_000).map { UInt8($0 % 251) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        let progress = Mutex<[Int]>([])
        let result = try await backend.uploadAttachment(OutgoingAttachment(
            id: "chosen", file: file, name: "chosen file", contentType: "application/octet-stream",
            byteSize: bytes.count
        ), to: Conversation.ID("same"), progress: { update in
            progress.withLock { $0.append(update.bytesReceived) }
        })
        #expect(result.byteSize == bytes.count)
        #expect(await tap.chunks.map(\.count) == [65536, 65536, 8928])
        #expect(await tap.chunks.reduce(Data(), +) == bytes)
        #expect(await tap.finalizations == 1)
        #expect(progress.withLock { $0 } == [0, 65536, 131_072, 140_000])
        let controls = await tap.controls
        for request in controls {
            let json = try String(decoding: ServiceCodec.encode(request), as: UTF8.self)
            #expect(!json.contains(file.path))
            #expect(!json.contains(bytes.base64EncodedString()))
        }
        let canonical = try await harness.canonical(harness.first.id)
        let references = try #require(canonical as? any ServiceUploadReferences)
        #expect(try references.uploadedAttachment(result.id, in: .init("same"), at: Date()) == result)
        await backend.disconnect()
        await harness.service.shutdown()
    }

    @Test func invalidLocalLengthRefusesBeforeAnyAllocationAndZeroLengthCanFinalize() async throws {
        let harness = try await ClientHarness.make(uploads: true)
        let tap = UploadTransportTap(base: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        let backend = ServiceBackend(account: harness.first, transport: tap)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        let wrong = OutgoingAttachment(
            id: "file",
            file: file,
            name: "empty",
            contentType: "text/plain",
            byteSize: 1
        )
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await backend.uploadAttachment(wrong, to: .init("same"), progress: { _ in })
        }
        #expect(await tap.controls.isEmpty)
        var empty = wrong
        empty.byteSize = 0
        #expect(try await backend.uploadAttachment(empty, to: .init("same"), progress: { _ in
        }).byteSize == 0)
        #expect(await tap.chunks.isEmpty)
        await backend.disconnect()
        await harness.service.shutdown()
    }

    @Test func disconnectDrainsHeldClientUploadAndCancelsItsServerReservation() async throws {
        let harness = try await ClientHarness.make(
            uploads: true,
            transferLimits: .init(maximumAccountTransfers: 1)
        )
        let tap = UploadTransportTap(base: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        await tap.holdChunk()
        let backend = ServiceBackend(account: harness.first, transport: tap)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: file)
        let outgoing = OutgoingAttachment(
            id: "file",
            file: file,
            name: "file",
            contentType: "text/plain",
            byteSize: 4
        )
        let upload = Task { try await backend.uploadAttachment(outgoing, to: .init("same"), progress: { _ in
        }) }
        try await eventually { await tap.held }
        let previous = await backend.connectionGeneration
        let stopping = Task { await backend.disconnect() }
        var handedOff = false
        for _ in 0 ..< 1000 {
            if await backend.connectionGeneration != previous {
                handedOff = true; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        await tap.release()
        #expect(handedOff)
        _ = await upload.result
        await stopping.value
        #expect(await tap.finalizations == 0)
        #expect(await tap.controls.contains { $0.operation == CancelTransfer.operation })
        let replacement = harness.backend(harness.first)
        #expect(try await replacement.uploadAttachment(outgoing, to: .init("same"), progress: { _ in
        }).byteSize == 4)
        await replacement.disconnect()
        await harness.service.shutdown()
    }
}

actor UploadTransportTap: ServiceEventTransport, ServiceBinaryTransport {
    let base: InProcessChatTransport
    private(set) var chunks: [Data] = []
    private(set) var controls: [ServiceRequest] = []
    private(set) var finalizations = 0
    private var loseFinalize = false
    private var hold = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var held = false

    init(base: InProcessChatTransport) {
        self.base = base
    }

    func dropFinalizationReply() {
        loseFinalize = true
    }

    func holdChunk() {
        hold = true
    }

    func release() {
        hold = false; waiter?.resume(); waiter = nil
    }

    func negotiate(_ peer: ServiceAPIVersion) async throws -> ServiceAPIVersion {
        try await base
            .negotiate(peer)
    }

    func events(_ request: ServiceRequest) async throws -> AsyncThrowingStream<ServiceEventPage, any Error> {
        try await base.events(request)
    }

    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        controls.append(request)
        let reply = try await base.exchange(request)
        if request.operation == FinalizeUploadTransfer.operation {
            finalizations += 1
            if loseFinalize {
                loseFinalize = false; throw ServiceFailure.deadlineExceeded
            }
        }
        return reply
    }

    func exchangeBinary(_ request: ServiceRequest, body: Data) async throws -> ServiceBinaryReply {
        chunks.append(body)
        if hold {
            held = true; await withCheckedContinuation { waiter = $0 }
        }
        return try await base.exchangeBinary(request, body: body)
    }
}
