import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    var transfersAreEmpty: Bool {
        uploads.isEmpty && downloads.isEmpty
    }

    var reservedTransferBytes: Int {
        uploads.values.reduce(0) { $0 + $1.request.metadata.byteSize } +
            downloads.values.reduce(0) { $0 + $1.descriptor.maximumBytes }
    }

    func dispatchDownload(
        _ request: ServiceRequest, backend: any ChatBackend, context: ServiceSessionContext?, epoch: UUID
    ) async throws -> JSONValue {
        guard let context else { throw ServiceFailure.notAuthorized }
        switch request.operation {
        case BeginDownloadTransfer.operation:
            let payload = try request.decodePayload(BeginDownloadTransfer.self)
            return try await ServiceCodec.value(beginDownload(
                payload,
                backend: backend,
                context: context,
                epoch: epoch
            ))
        case GetDownloadTransfer.operation:
            let payload = try request.decodePayload(GetDownloadTransfer.self)
            return try ServiceCodec
                .value(currentDownload(payload.transferID, owner: TransferOwner(context)).descriptor)
        default: throw ServiceFailure.unsupportedOperation
        }
    }

    private func beginDownload(
        _ payload: BeginDownloadTransfer, backend: any ChatBackend, context: ServiceSessionContext,
        epoch: UUID
    ) async throws -> DownloadTransfer {
        guard let provider = backend as? any BoundedMediaBackend,
              let files = transferStorage as? any ServiceDownloadStorage,
              let catalog = storage as? any ServiceMediaCatalog
        else { throw ServiceFailure.unsupportedOperation }
        guard payload.maximumBytes >= 0, !payload.operationID.rawValue.isEmpty,
              payload.operationID.rawValue.utf8.count <= 128 else { throw ServiceFailure.invalidRequest }
        let maximum = try downloadLimit(payload, capabilities: backend.capabilities)
        try await expireUploads()
        try checkEpoch(epoch)
        let owner = TransferOwner(context)
        if let old = downloads.values.first(where: {
            $0.owner == owner && $0.request.operationID == payload.operationID
        }) {
            guard old.request == payload else { throw ServiceFailure.operationConflict }
            return try currentDownload(old.descriptor.id, owner: owner).descriptor
        }
        guard let source = try catalog.mediaSources(for: payload.selector, at: transferNow()).first else {
            throw ServiceFailure.notAuthorized
        }
        guard uploads.count + downloads.count < transferLimits.maximumAccountTransfers,
              maximum <= transferLimits.maximumAccountBytes - reservedTransferBytes else {
            throw ServiceFailure.overloaded
        }
        let descriptor = DownloadTransfer(
            id: .init(UUID().uuidString),
            expiresAt: transferNow().addingTimeInterval(transferLimits.lifetime),
            chunkSize: ServiceBinaryLimits.maximumChunkBytes, maximumBytes: maximum, byteSize: nil,
            phase: "fetching"
        )
        try installDownload(
            DownloadSlot(owner: owner, request: payload, source: source, descriptor: descriptor),
            provider: provider, files: files, epoch: epoch
        )
        return descriptor
    }

    private func installDownload(
        _ initial: DownloadSlot, provider: any BoundedMediaBackend,
        files: any ServiceDownloadStorage, epoch: UUID
    ) throws {
        var slot = initial
        let descriptor = slot.descriptor
        let payload = slot.request
        do {
            let destination: URL?
            if payload.rendition == "file" {
                destination = try files.reserveDownload(descriptor.id, maximumBytes: descriptor.maximumBytes)
            } else {
                try files.create(descriptor.id, maximumBytes: descriptor.maximumBytes)
                destination = nil
            }
            downloads[descriptor.id] = slot
            slot.job = Task { [self] in
                await fetchDownload(descriptor.id, provider: provider, destination: destination, epoch: epoch)
            }
            downloads[descriptor.id] = slot
        } catch {
            slot.retired = true
            downloads[descriptor.id] = slot
            startUploadExpiry()
            throw error
        }
        startUploadExpiry()
    }

    private func downloadLimit(_ payload: BeginDownloadTransfer, capabilities: Capabilities) throws -> Int {
        let supported: Bool
        switch (payload.selector, payload.rendition) {
        case (.attachment, "file"): supported = capabilities.canDownloadFiles
        case (.attachment, "preview"), (.attachment, "original"): supported = capabilities.canFetchAttachments
        case (.customEmoji, "image"): supported = capabilities.canFetchCustomEmoji
        case (.remoteImage, "image"): supported = capabilities.canFetchRemoteImages
        default: throw ServiceFailure.unsupportedOperation
        }
        guard supported else { throw ServiceFailure.unsupportedOperation }
        let ceiling = payload.rendition == "file" ? transferLimits.maximumFileBytes :
            min(10 * 1024 * 1024, transferLimits.maximumFileBytes)
        return min(payload.maximumBytes, ceiling)
    }

    func currentDownload(_ id: ServiceTransferID, owner: TransferOwner) throws -> DownloadSlot {
        guard let slot = downloads[id] else { throw ServiceFailure.transferExpired }
        guard slot.owner == owner else { throw ServiceFailure.notAuthorized }
        guard !slot.retired,
              slot.descriptor.expiresAt > transferNow() else { throw ServiceFailure.transferExpired }
        if let failure = slot.failure {
            throw failure
        }
        guard let catalog = storage as? any ServiceMediaCatalog,
              try catalog.isCurrentMediaSource(slot.source, at: transferNow()) else {
            throw ServiceFailure.notAuthorized
        }
        return slot
    }

    func readDownload(
        _ request: ReadTransferChunk,
        context: ServiceSessionContext
    ) throws -> (TransferChunkReceipt, Data) {
        let slot = try currentDownload(request.transferID, owner: TransferOwner(context))
        guard let size = slot.descriptor.byteSize, slot.descriptor.phase == "ready",
              let files = transferStorage else {
            throw ServiceFailure.operationConflict
        }
        guard request.offset <= Int64(size) else { throw ServiceFailure.invalidRequest }
        let count = min(request.count, size - Int(request.offset))
        let bytes = try files.read(request.transferID, at: request.offset, count: count)
        guard bytes.count == count else { throw ServiceFailure.invalidResponse }
        let next = request.offset + Int64(bytes.count)
        return (
            TransferChunkReceipt(
                transferID: request.transferID,
                nextOffset: next,
                isComplete: next == Int64(size)
            ),
            bytes
        )
    }
}
