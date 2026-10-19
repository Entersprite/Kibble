import ChatAPI
import Foundation

actor BinaryEndpoint: ServiceBinaryEndpoint {
    enum Mode: Sendable {
        case normal, held, wrongRequest, wrongAccount, wrongRevision, wrongVersion, malformed,
             largeHeader, largeBody, failureWithBytes, unknownWithBytes, wrongHandle, wrongOffset,
             excessRead, stalledRead, writeWithBytes, malformedReceipt
    }

    struct Received: Sendable {
        let request: ServiceRequest
        let body: Data
        let context: ServiceSessionContext
    }

    let mode: Mode
    private(set) var received: [Received] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(_ mode: Mode = .normal) {
        self.mode = mode
    }

    func handle(_ header: Data, context _: ServiceSessionContext) throws -> Data {
        let request = try ServiceCodec.decode(ServiceRequest.self, from: header)
        return try ServiceCodec.encode(ServiceResponse(replyingTo: request, result: .success(.null)))
    }

    func binary(
        _ header: Data,
        body: Data,
        context: ServiceSessionContext
    ) async throws -> ServiceBinaryFrame {
        let request = try ServiceCodec.decode(ServiceRequest.self, from: header)
        received.append(Received(request: request, body: body, context: context))
        if mode == .held, !released {
            await withCheckedContinuation { held.append($0) }
        }
        if mode == .malformed {
            return ServiceBinaryFrame(header: Data("bad".utf8), body: Data())
        }
        if mode == .largeHeader {
            return ServiceBinaryFrame(
                header: Data(repeating: 0, count: ServiceBinaryLimits.maximumHeaderBytes + 1), body: Data()
            )
        }
        if mode == .largeBody {
            return ServiceBinaryFrame(
                header: Data(), body: Data(repeating: 0, count: ServiceBinaryLimits.maximumChunkBytes + 1)
            )
        }
        return try frame(for: request, body: body)
    }

    private func frame(for request: ServiceRequest, body: Data) throws -> ServiceBinaryFrame {
        let id: ServiceTransferID
        let offset: Int64
        var reply: Data
        if request.operation == ReadTransferChunk.operation {
            let payload = try request.decodePayload(ReadTransferChunk.self)
            id = payload.transferID
            offset = payload.offset
            reply = Data(repeating: 42, count: payload.count + (mode == .excessRead ? 1 : 0))
            if mode == .stalledRead {
                reply = Data()
            }
        } else {
            let payload = try request.decodePayload(WriteTransferChunk.self)
            id = payload.transferID
            offset = payload.offset
            reply = mode == .writeWithBytes ? Data([1]) : Data()
        }
        let count = request.operation == ReadTransferChunk.operation ? reply.count : body.count
        let receipt = TransferChunkReceipt(
            transferID: mode == .wrongHandle ? ServiceTransferID("foreign") : id,
            nextOffset: offset + Int64(count) + (mode == .wrongOffset ? 1 : 0), isComplete: false
        )
        var result = try ServiceResult.success(ServiceCodec.value(receipt))
        if mode == .malformedReceipt {
            result = .success(.object(["nextOffset": .string("bad")]))
        }
        if mode == .failureWithBytes {
            result = .failure(.notAuthorized)
        }
        if mode == .unknownWithBytes {
            result = .unknown(
                type: "future",
                payload: .object(["extra": .bool(true)])
            )
        }
        let response = ServiceResponse(
            requestID: mode == .wrongRequest ? ServiceRequestID("foreign") : request.header.requestID,
            accountID: mode == .wrongAccount ? accountB : request.header.accountID,
            result: result,
            accountRevision: mode == .wrongRevision ? ServiceAccountRevision("foreign") : request.header
                .accountRevision,
            version: mode == .wrongVersion ? ServiceAPIVersion(major: 2, minor: 0) : request.header.version
        )
        return try ServiceBinaryFrame(header: ServiceCodec.encode(response), body: reply)
    }

    func release() {
        released = true
        let waiting = held
        held = []
        for continuation in waiting {
            continuation.resume()
        }
    }
}
