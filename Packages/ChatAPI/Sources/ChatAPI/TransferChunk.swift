import Foundation

public enum ServiceTransferScope: Sendable {}
public typealias ServiceTransferID = ServiceID<ServiceTransferScope>

/// Offsets refer only to a service-issued, account-scoped transfer handle.
public struct ReadTransferChunk: ServiceRequestPayload {
    public typealias Response = TransferChunkReceipt
    public static let operation = "readTransferChunk"
    public static let requiresAccount = true
    public let transferID: ServiceTransferID
    private let encodedOffset: TransferOffset
    public var offset: Int64 {
        encodedOffset.value
    }

    public let count: Int

    private enum CodingKeys: String, CodingKey { case transferID, count, encodedOffset = "offset" }

    public init(transferID: ServiceTransferID, offset: Int64, count: Int) {
        self.transferID = transferID
        encodedOffset = TransferOffset(value: offset)
        self.count = count
    }
}

public struct WriteTransferChunk: ServiceRequestPayload {
    public typealias Response = TransferChunkReceipt
    public static let operation = "writeTransferChunk"
    public static let requiresAccount = true
    public let transferID: ServiceTransferID
    private let encodedOffset: TransferOffset
    public var offset: Int64 {
        encodedOffset.value
    }

    public let count: Int

    private enum CodingKeys: String, CodingKey { case transferID, count, encodedOffset = "offset" }

    public init(transferID: ServiceTransferID, offset: Int64, count: Int) {
        self.transferID = transferID
        encodedOffset = TransferOffset(value: offset)
        self.count = count
    }
}

public struct TransferChunkReceipt: Codable, Hashable, Sendable {
    public let transferID: ServiceTransferID
    private let encodedOffset: TransferOffset
    public var nextOffset: Int64 {
        encodedOffset.value
    }

    public let isComplete: Bool

    private enum CodingKeys: String, CodingKey { case transferID, isComplete, encodedOffset = "nextOffset" }

    public init(transferID: ServiceTransferID, nextOffset: Int64, isComplete: Bool) {
        self.transferID = transferID
        encodedOffset = TransferOffset(value: nextOffset)
        self.isComplete = isComplete
    }
}

public extension ServiceRequest {
    /// Rechecked by transports and services; raw requests cannot bypass typed scopes.
    func validateBinaryBody(_ body: Data) throws {
        guard body.count <= ServiceBinaryLimits.maximumChunkBytes else { throw ServiceFailure.frameTooLarge }
        let offset: Int64
        let count: Int
        switch operation {
        case ReadTransferChunk.operation:
            let payload = try decodePayload(ReadTransferChunk.self)
            guard body.isEmpty else { throw ServiceFailure.invalidRequest }
            offset = payload.offset
            count = payload.count
        case WriteTransferChunk.operation:
            let payload = try decodePayload(WriteTransferChunk.self)
            guard body.count == payload.count else { throw ServiceFailure.invalidRequest }
            offset = payload.offset
            count = payload.count
        default: throw ServiceFailure.unsupportedOperation
        }
        guard offset >= 0, count > 0, count <= ServiceBinaryLimits.maximumChunkBytes,
              offset <= Int64.max - Int64(count) else { throw ServiceFailure.invalidRequest }
    }
}

/// Decimal strings preserve offsets exactly through JSONValue and non-Swift peers.
private struct TransferOffset: Codable, Hashable, Sendable {
    let value: Int64

    init(value: Int64) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Int64(raw), String(value) == raw else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid byte offset")
        }
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }
}
