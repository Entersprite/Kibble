import ChatKit

public struct GetSyncedDrafts: ServiceRequestPayload {
    public typealias Response = SyncedDraftPage
    public static let operation = "getSyncedDrafts"
    public static let requiresAccount = true

    public let address: ComposerDraftAddress?
    public let cursor: String?

    public init(address: ComposerDraftAddress?, cursor: String?) {
        self.address = address
        self.cursor = cursor
    }
}

public struct WriteSyncedDraft: ServiceRequestPayload {
    public typealias Response = SyncedDraftWriteResult
    public static let operation = "writeSyncedDraft"
    public static let requiresAccount = true

    public let change: SyncedDraftChange
    public let operationID: ServiceOperationID

    public init(change: SyncedDraftChange, operationID: ServiceOperationID) {
        self.change = change
        self.operationID = operationID
    }
}
