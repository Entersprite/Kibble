import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ServiceClient

struct UploadProgressProjectionTests {
    private let transfer = UploadTransfer(
        id: .init("upload"), expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
        chunkSize: 65536, byteSize: 8
    )

    @Test func anUntrustedStatusCannotChangeScopeMetadataOrClaimCompletion() throws {
        var projection = UploadProgressProjection(transfer: transfer)
        let foreign = UploadTransfer(
            id: .init("foreign"), expiresAt: transfer.expiresAt, chunkSize: 65536, byteSize: 8
        )
        let changed = UploadTransfer(
            id: transfer.id, expiresAt: transfer.expiresAt.addingTimeInterval(1), chunkSize: 65536,
            byteSize: 8
        )
        for invalid in [
            UploadTransferStatus(transfer: foreign, phase: "uploading", stagedBytes: 8, providerBytesSent: 3),
            UploadTransferStatus(transfer: changed, phase: "uploading", stagedBytes: 8, providerBytesSent: 3),
            UploadTransferStatus(transfer: transfer, phase: "future", stagedBytes: 8, providerBytesSent: 3),
            UploadTransferStatus(
                transfer: transfer,
                phase: "uploading",
                stagedBytes: 7,
                providerBytesSent: 3
            ),
            UploadTransferStatus(
                transfer: transfer,
                phase: "uploading",
                stagedBytes: 8,
                providerBytesSent: -1
            ),
            UploadTransferStatus(
                transfer: transfer,
                phase: "uploading",
                stagedBytes: 8,
                providerBytesSent: 9
            ),
            UploadTransferStatus(transfer: transfer, phase: "receiving", stagedBytes: 8, providerBytesSent: 3)
        ] {
            #expect(throws: ServiceFailure.invalidResponse) { try projection.accept(invalid) }
        }
        #expect(try projection.accept(.init(
            transfer: transfer, phase: "uploading", stagedBytes: 8, providerBytesSent: 3
        )) == AttachmentProgress(bytesReceived: 11, totalBytes: 16))
        #expect(try projection.accept(.init(
            transfer: transfer, phase: "uploading", stagedBytes: 8, providerBytesSent: 2
        )) == nil)
        #expect(try projection.accept(.init(
            transfer: transfer, phase: "uploading", stagedBytes: 8, providerBytesSent: 8
        )) == AttachmentProgress(bytesReceived: 15, totalBytes: 16))
    }
}
