import ChatAPI
import Foundation
import InProcessChatTransport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BinaryTransportTests {
    func chunk(
        id: String = "chunk", account: ConnectedAccountID = accountA, deadline: Date? = nil,
        offset: Int64 = 0, count: Int = 4, writing: Bool = false
    ) throws -> ServiceRequest {
        let header = ServiceRequestHeader(
            requestID: ServiceRequestID(id), accountID: account,
            accountRevision: ServiceAccountRevision("binding"), deadline: deadline
        )
        let transfer = ServiceTransferID("transfer")
        if writing {
            return try ServiceRequest(header: header, payload: WriteTransferChunk(
                transferID: transfer, offset: offset, count: count
            ))
        }
        return try ServiceRequest(header: header, payload: ReadTransferChunk(
            transferID: transfer, offset: offset, count: count
        ))
    }

    @Test func chunksKeepBinaryOutsideSerializedMetadataAndBindTrustedContext() async throws {
        let endpoint = BinaryEndpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        _ = try await transport.negotiate(.current)
        let bytes = Data([0, 255, 128, 0])
        let upload = try chunk(writing: true)
        let result = try await transport.exchangeBinary(upload, body: bytes)
        #expect(result.body.isEmpty)
        #expect(try result.response.value(for: WriteTransferChunk.self).nextOffset == 4)
        let received = try #require(await endpoint.received.first)
        #expect(received.request == upload)
        #expect(received.body == bytes)
        #expect(received.context == context())
        let json = try String(decoding: ServiceCodec.encode(upload), as: UTF8.self)
        #expect(!json.contains(bytes.base64EncodedString()))
        let download = try await transport.exchangeBinary(chunk(id: "download"), body: Data())
        #expect(download.body == Data(repeating: 42, count: 4))
    }

    @Test func offsetsRoundTripExactlyAboveJavaScriptIntegerPrecision() throws {
        let offset: Int64 = 9_007_199_254_740_993
        let request = try chunk(offset: offset)
        let encoded = try ServiceCodec.encode(request)
        let decoded = try ServiceCodec.decode(ServiceRequest.self, from: encoded)
        #expect(try decoded.decodePayload(ReadTransferChunk.self).offset == offset)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"offset\":\"9007199254740993\""))
        let receipt = TransferChunkReceipt(
            transferID: ServiceTransferID("transfer"), nextOffset: offset + 4, isComplete: true
        )
        #expect(try ServiceCodec.decode(
            TransferChunkReceipt.self, from: ServiceCodec.value(receipt)
        ) == receipt)
    }

    @Test func maximumChunkSucceedsAndControlOnlyPeerRefusesBinary() async throws {
        let endpoint = BinaryEndpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        _ = try await transport.negotiate(.current)
        let bytes = Data(repeating: 0, count: ServiceBinaryLimits.maximumChunkBytes)
        _ = try await transport.exchangeBinary(chunk(count: bytes.count, writing: true), body: bytes)
        let download = try await transport.exchangeBinary(chunk(id: "read", count: bytes.count), body: Data())
        #expect(download.body.count == bytes.count)
        let controlOnly = InProcessChatTransport(endpoint: Endpoint(), context: context())
        _ = try await controlOnly.negotiate(.current)
        await #expect(throws: ServiceFailure.unsupportedOperation) {
            try await controlOnly.exchangeBinary(chunk(), body: Data())
        }
    }

    @Test func oversizedMetadataAndNonTransferOperationsNeverDispatch() async throws {
        let endpoint = BinaryEndpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        _ = try await transport.negotiate(.current)
        let oversized = try ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID("large"), accountID: accountA),
            payload: ReadTransferChunk(
                transferID: ServiceTransferID(String(repeating: "x", count: 65536)), offset: 0, count: 4
            )
        )
        await #expect(throws: ServiceFailure.frameTooLarge) {
            try await transport.exchangeBinary(oversized, body: Data())
        }
        await #expect(throws: ServiceFailure.unsupportedOperation) {
            try await transport.exchangeBinary(request(account: accountA), body: Data())
        }
        #expect(await endpoint.received.isEmpty)
    }

    @Test(arguments: [
        BinaryEndpoint.Mode.wrongRequest,
        .wrongAccount,
        .wrongRevision,
        .wrongVersion,
        .malformed,
        .failureWithBytes,
        .unknownWithBytes,
        .wrongHandle,
        .wrongOffset,
        .excessRead,
        .stalledRead,
        .malformedReceipt
    ])
    func malformedOrForeignReplyNeverReachesTheClient(_ mode: BinaryEndpoint.Mode) async throws {
        let transport = InProcessChatTransport(endpoint: BinaryEndpoint(mode), context: context())
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.invalidResponse) {
            try await transport.exchangeBinary(chunk(), body: Data())
        }
    }

    @Test(arguments: [BinaryEndpoint.Mode.largeHeader, .largeBody])
    func byteAndMetadataResponseLimitsAreIndependent(_ mode: BinaryEndpoint.Mode) async throws {
        let transport = InProcessChatTransport(endpoint: BinaryEndpoint(mode), context: context())
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.frameTooLarge) {
            try await transport.exchangeBinary(chunk(), body: Data())
        }
    }

    @Test func writeAcknowledgementCannotSmuggleDownloadBytes() async throws {
        let transport = InProcessChatTransport(endpoint: BinaryEndpoint(.writeWithBytes), context: context())
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.invalidResponse) {
            try await transport.exchangeBinary(chunk(writing: true), body: Data([1, 2, 3, 4]))
        }
    }

    @Test func accountHandshakeShapeAndRangeChecksPrecedeDispatch() async throws {
        let endpoint = BinaryEndpoint()
        let transport = InProcessChatTransport(endpoint: endpoint, context: context())
        await #expect(throws: ServiceFailure.handshakeRequired) {
            try await transport.exchangeBinary(chunk(), body: Data())
        }
        _ = try await transport.negotiate(.current)
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await transport.exchangeBinary(chunk(account: accountB), body: Data())
        }
        for (offset, count) in [(Int64(-1), 4), (Int64.max, 4), (Int64(0), 0), (Int64(0), 65537)] {
            await #expect(throws: ServiceFailure.invalidRequest) {
                try await transport.exchangeBinary(chunk(offset: offset, count: count), body: Data())
            }
        }
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await transport.exchangeBinary(chunk(writing: true), body: Data([1]))
        }
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await transport.exchangeBinary(chunk(), body: Data([1]))
        }
        await #expect(throws: ServiceFailure.frameTooLarge) {
            try await transport.exchangeBinary(chunk(writing: true), body: Data(repeating: 0, count: 65537))
        }
        #expect(await endpoint.received.isEmpty)
    }

    @Test(arguments: [true, false])
    func abandonedBinaryWorkRetainsSharedBudgetUntilItActuallyDrains(cancel: Bool) async throws {
        let endpoint = BinaryEndpoint(.held)
        let transport = InProcessChatTransport(endpoint: endpoint, context: context(), maximumInFlight: 1)
        _ = try await transport.negotiate(.current)
        let heldRequest = try chunk(deadline: cancel ? nil : Date().addingTimeInterval(0.05))
        let held = Task { try await transport.exchangeBinary(heldRequest, body: Data()) }
        try await wait { await !endpoint.received.isEmpty }
        await #expect(throws: ServiceFailure.duplicateRequest) {
            try await transport.exchangeBinary(heldRequest, body: Data())
        }
        await #expect(throws: ServiceFailure.duplicateRequest) {
            try await transport.exchange(request(id: "chunk", account: accountA))
        }
        if cancel {
            held.cancel()
            await #expect(throws: CancellationError.self) { try await held.value }
        } else {
            await #expect(throws: ServiceFailure.deadlineExceeded) { try await held.value }
        }
        await #expect(throws: ServiceFailure.overloaded) {
            try await transport.exchange(request(id: "ordinary", account: accountA))
        }
        await endpoint.release()
        try await wait {
            do {
                _ = try await transport.exchange(request(id: "after", account: accountA))
                return true
            } catch let error as ServiceFailure where error == .overloaded {
                return false
            }
        }
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ServiceFailure.deadlineExceeded
    }
}
