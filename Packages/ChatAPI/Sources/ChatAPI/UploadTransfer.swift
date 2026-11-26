import ChatKit
import Foundation

/// Descriptive metadata only; a client file URL has no service-side meaning.
public struct UploadFileMetadata: Codable, Hashable, Sendable {
    public let name: String
    public let contentType: String
    public let byteSize: Int
    public let width: Int?
    public let height: Int?

    public init(name: String, contentType: String, byteSize: Int, width: Int? = nil, height: Int? = nil) {
        self.name = name
        self.contentType = contentType
        self.byteSize = byteSize
        self.width = width
        self.height = height
    }
}

public struct BeginUploadTransfer: ServiceRequestPayload {
    public typealias Response = UploadTransfer
    public static let operation = "beginUploadTransfer"
    public static let requiresAccount = true
    public let operationID: ServiceOperationID
    public let conversationID: Conversation.ID
    public let metadata: UploadFileMetadata

    public init(
        operationID: ServiceOperationID,
        conversationID: Conversation.ID,
        metadata: UploadFileMetadata
    ) {
        self.operationID = operationID
        self.conversationID = conversationID
        self.metadata = metadata
    }
}

public struct UploadTransfer: Codable, Hashable, Sendable {
    public let id: ServiceTransferID
    public let expiresAt: Date
    public let chunkSize: Int
    public let byteSize: Int

    public init(id: ServiceTransferID, expiresAt: Date, chunkSize: Int, byteSize: Int) {
        self.id = id
        self.expiresAt = expiresAt
        self.chunkSize = chunkSize
        self.byteSize = byteSize
    }
}

public struct FinalizeUploadTransfer: ServiceRequestPayload {
    public typealias Response = Attachment
    public static let operation = "finalizeUploadTransfer"
    public static let requiresAccount = true
    public let transferID: ServiceTransferID
    public let operationID: ServiceOperationID

    public init(transferID: ServiceTransferID, operationID: ServiceOperationID) {
        self.transferID = transferID
        self.operationID = operationID
    }
}

public struct CancelTransfer: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "cancelTransfer"
    public static let requiresAccount = true
    public let transferID: ServiceTransferID

    public init(transferID: ServiceTransferID) {
        self.transferID = transferID
    }
}
