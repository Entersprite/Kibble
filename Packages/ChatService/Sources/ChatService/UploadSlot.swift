import ChatAPI
import ChatKit
import Foundation

struct TransferOwner: Hashable, Sendable {
    let principal: ServicePrincipalID
    let device: ServiceDeviceID
    let session: ClientSessionID

    init(_ context: ServiceSessionContext) {
        principal = context.principalID
        device = context.deviceID
        session = context.sessionID
    }
}

struct UploadSlot: Sendable {
    let owner: TransferOwner
    let request: BeginUploadTransfer
    let descriptor: UploadTransfer
    let providerProgress = UploadProviderProgress()
    var received = 0
    var retired = false
    var operation: ServiceOperationID?
    var job: Task<JSONValue, any Error>?
}
