import ChatAPI
import Foundation
import InProcessChatTransport

actor DownloadTransportTap: ServiceEventTransport, ServiceBinaryTransport {
    let base: InProcessChatTransport
    var failSecond = false
    var holdSecond = false
    var held = false
    var waiter: CheckedContinuation<Void, Never>?
    private(set) var requests: [ServiceRequest] = []
    private(set) var chunks: [Data] = []

    init(base: InProcessChatTransport) {
        self.base = base
    }

    func failAfterFirstChunk() {
        failSecond = true
    }

    func holdAfterFirstChunk() {
        holdSecond = true
    }

    func release() {
        holdSecond = false; waiter?.resume(); waiter = nil
    }

    func negotiate(_ peer: ServiceAPIVersion) async throws -> ServiceAPIVersion {
        try await base
            .negotiate(peer)
    }

    func events(_ request: ServiceRequest) async throws -> AsyncThrowingStream<ServiceEventPage, any Error> {
        try await base.events(request)
    }

    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        requests.append(request)
        let reply = try await base.exchange(request)
        guard request.operation == BeginDownloadTransfer.operation || request.operation == GetDownloadTransfer
            .operation,
            case let .success(value) = reply.result else { return reply }
        let actual = try ServiceCodec.decode(DownloadTransfer.self, from: value)
        let smallChunks = DownloadTransfer(
            id: actual.id, expiresAt: actual.expiresAt, chunkSize: 7,
            maximumBytes: actual.maximumBytes, byteSize: actual.byteSize, phase: actual.phase
        )
        return try ServiceResponse(replyingTo: request, result: .success(ServiceCodec.value(smallChunks)))
    }

    func exchangeBinary(_ request: ServiceRequest, body: Data) async throws -> ServiceBinaryReply {
        requests.append(request)
        let reply = try await base.exchangeBinary(request, body: body)
        chunks.append(reply.body)
        if chunks.count == 2 {
            if failSecond {
                throw ServiceFailure.invalidResponse
            }
            if holdSecond {
                held = true
                await withCheckedContinuation { waiter = $0 }
            }
        }
        return reply
    }
}
