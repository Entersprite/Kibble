import ChatAPI
import Foundation

struct DownloadSlot: Sendable {
    let owner: TransferOwner
    let request: BeginDownloadTransfer
    let source: IssuedMediaSource
    var descriptor: DownloadTransfer
    var retired = false
    var failure: ServiceFailure?
    var job: Task<Void, Never>?
}
