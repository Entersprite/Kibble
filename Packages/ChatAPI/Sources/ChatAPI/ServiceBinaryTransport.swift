import Foundation

/// Framing limits belong to the byte transport, independently of chat JSON.
public enum ServiceBinaryLimits {
    public static let maximumChunkBytes = 64 * 1024
    public static let maximumHeaderBytes = 64 * 1024
}

/// The header is serialized ServiceResponse data; body bytes never enter JSON.
public struct ServiceBinaryFrame: Sendable {
    public let header: Data
    public let body: Data

    public init(header: Data, body: Data) {
        self.header = header
        self.body = body
    }
}

public struct ServiceBinaryReply: Sendable {
    public let response: ServiceResponse
    public let body: Data

    public init(response: ServiceResponse, body: Data) {
        self.response = response
        self.body = body
    }
}

public extension ServiceBinaryReply {
    /// Refuse mismatched handles, excess bytes and acknowledgements of unwritten data.
    func validateChunk(for request: ServiceRequest) throws {
        switch response.result {
        case .success: break
        default:
            guard body.isEmpty else { throw ServiceFailure.invalidResponse }
            return
        }
        let receipt: TransferChunkReceipt
        let id: ServiceTransferID
        let expected: Int64
        switch request.operation {
        case ReadTransferChunk.operation:
            let payload = try request.decodePayload(ReadTransferChunk.self)
            receipt = try response.value(for: ReadTransferChunk.self)
            guard body.count <= payload.count, !body.isEmpty || receipt.isComplete else {
                throw ServiceFailure.invalidResponse
            }
            id = payload.transferID
            expected = try nextOffset(payload.offset, count: body.count)
        case WriteTransferChunk.operation:
            let payload = try request.decodePayload(WriteTransferChunk.self)
            receipt = try response.value(for: WriteTransferChunk.self)
            guard body.isEmpty else { throw ServiceFailure.invalidResponse }
            id = payload.transferID
            guard payload.count >= 1 else { throw ServiceFailure.invalidResponse }
            expected = try nextOffset(payload.offset, count: payload.count)
        default: throw ServiceFailure.unsupportedOperation
        }
        guard receipt.transferID == id, receipt.nextOffset == expected else {
            throw ServiceFailure.invalidResponse
        }
    }

    private func nextOffset(_ offset: Int64, count: Int) throws -> Int64 {
        guard count >= 0, count <= ServiceBinaryLimits.maximumChunkBytes,
              offset >= 0, offset <= Int64.max - Int64(count) else {
            throw ServiceFailure.invalidResponse
        }
        return offset + Int64(count)
    }
}

/// The host binds the same trusted context as ordinary control requests.
public protocol ServiceBinaryEndpoint: ServiceEndpoint {
    func binary(
        _ header: Data, body: Data, context: ServiceSessionContext
    ) async throws -> ServiceBinaryFrame
}

public protocol ServiceBinaryTransport: ServiceTransport {
    func exchangeBinary(_ request: ServiceRequest, body: Data) async throws -> ServiceBinaryReply
}
