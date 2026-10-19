import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func fetchDownload(
        _ id: ServiceTransferID, provider: any BoundedMediaBackend, destination: URL?, epoch: UUID
    ) async {
        do {
            guard let initial = downloads[id] else { return }
            let slot = try currentDownload(id, owner: initial.owner)
            let maximum = slot.descriptor.maximumBytes
            guard let files = transferStorage as? any ServiceDownloadStorage else {
                throw ServiceFailure.unsupportedOperation
            }
            if let destination, case let .attachment(attachment) = slot.source.source {
                try await provider.downloadAttachment(
                    attachment,
                    to: destination,
                    maximumBytes: maximum,
                    progress: { _ in }
                )
            } else {
                let bytes = try await fetchMediaData(slot, provider: provider)
                try checkEpoch(epoch)
                _ = try currentDownload(id, owner: slot.owner)
                guard bytes.count <= maximum else { throw ServiceFailure.frameTooLarge }
                var offset = 0
                while offset < bytes.count {
                    let end = min(bytes.count, offset + ServiceBinaryLimits.maximumChunkBytes)
                    try files.append(bytes.subdata(in: offset ..< end), to: id, at: Int64(offset))
                    offset = end
                }
            }
            // No suspension separates revocation validation and ready publication.
            try checkEpoch(epoch)
            _ = try currentDownload(id, owner: slot.owner)
            let count = try files.completeDownload(id)
            downloads[id]?.descriptor = DownloadTransfer(
                id: id, expiresAt: slot.descriptor.expiresAt, chunkSize: slot.descriptor.chunkSize,
                maximumBytes: maximum, byteSize: count, phase: "ready"
            )
        } catch {
            downloads[id]?.failure = serviceFailure(error)
            do { try transferStorage?.remove(id) } catch { await reportUploadCleanupFailure() }
        }
        downloads[id]?.job = nil
    }

    private func fetchMediaData(
        _ slot: DownloadSlot,
        provider: any BoundedMediaBackend
    ) async throws -> Data {
        let maximum = slot.descriptor.maximumBytes
        switch slot.source.source {
        case let .attachment(attachment):
            guard let size = AttachmentSize(rawValue: slot.request.rendition) else {
                throw ServiceFailure.unsupportedOperation
            }
            return try await provider.attachmentData(attachment, size: size, maximumBytes: maximum)
        case let .customEmoji(emoji): return try await provider.customEmojiImage(emoji, maximumBytes: maximum)
        case let .remoteImage(url): return try await provider.remoteImage(url, maximumBytes: maximum)
        }
    }

    func cancelDownload(_ id: ServiceTransferID, owner: TransferOwner) async throws {
        guard var slot = downloads[id] else { return }
        guard slot.owner == owner else { throw ServiceFailure.notAuthorized }
        slot.retired = true
        downloads[id] = slot
        slot.job?.cancel()
        await slot.job?.value
        try transferStorage?.remove(id)
        downloads[id] = nil
        if transfersAreEmpty {
            uploadExpiry?.cancel(); uploadExpiry = nil
        }
    }

    func expireDownloads() async throws {
        let expired = downloads.filter { $0.value.retired || $0.value.descriptor.expiresAt <= transferNow() }
        for (id, slot) in expired {
            try await cancelDownload(id, owner: slot.owner)
        }
    }
}
