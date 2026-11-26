import Foundation

public struct GetUploadTransfer: ServiceRequestPayload {
    public typealias Response = UploadTransferStatus
    public static let operation = "getUploadTransfer"
    public static let requiresAccount = true
    public let transferID: ServiceTransferID

    public init(transferID: ServiceTransferID) {
        self.transferID = transferID
    }
}

/// Ephemeral progress only. The finalization operation remains the authority
/// for success or uncertain delivery after this transfer has been retired.
public struct UploadTransferStatus: Codable, Hashable, Sendable {
    public let transfer: UploadTransfer
    /// "receiving" or "uploading". Unknown phases are not completion.
    public let phase: String
    public let stagedBytes: Int
    public let providerBytesSent: Int

    public init(transfer: UploadTransfer, phase: String, stagedBytes: Int, providerBytesSent: Int) {
        self.transfer = transfer
        self.phase = phase
        self.stagedBytes = stagedBytes
        self.providerBytesSent = providerBytesSent
    }
}
