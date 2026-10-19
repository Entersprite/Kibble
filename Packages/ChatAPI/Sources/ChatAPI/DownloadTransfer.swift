import Foundation

public struct BeginDownloadTransfer: ServiceRequestPayload, Hashable {
    public typealias Response = DownloadTransfer
    public static let operation = "beginDownloadTransfer"
    public static let requiresAccount = true
    public let operationID: ServiceOperationID
    public let selector: MediaSelector
    /// "file", "preview", "original" or "image"; unknown renditions refuse.
    public let rendition: String
    public let maximumBytes: Int

    public init(
        operationID: ServiceOperationID, selector: MediaSelector, rendition: String, maximumBytes: Int
    ) {
        self.operationID = operationID
        self.selector = selector
        self.rendition = rendition
        self.maximumBytes = maximumBytes
    }
}

public struct GetDownloadTransfer: ServiceRequestPayload {
    public typealias Response = DownloadTransfer
    public static let operation = "getDownloadTransfer"
    public static let requiresAccount = true
    public let transferID: ServiceTransferID

    public init(transferID: ServiceTransferID) {
        self.transferID = transferID
    }
}

/// A ready descriptor has an exact byteSize. Fetching is independent of polling.
public struct DownloadTransfer: Codable, Hashable, Sendable {
    public let id: ServiceTransferID
    public let expiresAt: Date
    public let chunkSize: Int
    public let maximumBytes: Int
    public let byteSize: Int?
    public let phase: String

    public init(
        id: ServiceTransferID, expiresAt: Date, chunkSize: Int, maximumBytes: Int,
        byteSize: Int?, phase: String
    ) {
        self.id = id
        self.expiresAt = expiresAt
        self.chunkSize = chunkSize
        self.maximumBytes = maximumBytes
        self.byteSize = byteSize
        self.phase = phase
    }
}
