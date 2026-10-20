import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchUpload(
        _ request: ServiceRequest, backend: any ChatBackend, context: ServiceSessionContext?, epoch: UUID
    ) async throws -> JSONValue {
        guard let context else { throw ServiceFailure.notAuthorized }
        switch request.operation {
        case GetUploadTransfer.operation:
            let payload = try request.decodePayload(GetUploadTransfer.self)
            let slot = try currentUpload(payload.transferID, owner: TransferOwner(context))
            return try ServiceCodec.value(UploadTransferStatus(
                transfer: slot.descriptor, phase: slot.job == nil ? "receiving" : "uploading",
                stagedBytes: slot.received, providerBytesSent: slot.providerProgress.bytesSent
            ))
        case BeginUploadTransfer.operation:
            let payload = try request.decodePayload(BeginUploadTransfer.self)
            return try await ServiceCodec.value(beginUpload(
                payload,
                backend: backend,
                context: context,
                epoch: epoch
            ))
        case FinalizeUploadTransfer.operation:
            let payload = try request.decodePayload(FinalizeUploadTransfer.self)
            return try await finalizeUpload(
                payload,
                request: request,
                backend: backend,
                context: context,
                epoch: epoch
            )
        case CancelTransfer.operation:
            let payload = try request.decodePayload(CancelTransfer.self)
            try await cancelDownload(payload.transferID, owner: TransferOwner(context))
            try await cancelUpload(payload.transferID, owner: TransferOwner(context))
            return try ServiceCodec.value(ServiceUnit())
        default: throw ServiceFailure.unsupportedOperation
        }
    }

    private func beginUpload(
        _ payload: BeginUploadTransfer, backend: any ChatBackend, context: ServiceSessionContext, epoch: UUID
    ) async throws -> UploadTransfer {
        guard backend.capabilities.canSendAttachments, transferStorage != nil,
              storage is any ServiceUploadReferences else { throw ServiceFailure.unsupportedOperation }
        try validateUpload(payload)
        try await authorizeUploadConversation(payload.conversationID, backend: backend, epoch: epoch)
        try await expireUploads()
        try checkEpoch(epoch)
        let owner = TransferOwner(context)
        if let existing = uploads.values.first(where: {
            $0.owner == owner && $0.request.operationID == payload.operationID
        }) {
            guard existing.request == payload else { throw ServiceFailure.operationConflict }
            guard !existing.retired else { throw ServiceFailure.transferExpired }
            return existing.descriptor
        }
        let bytes = reservedTransferBytes
        guard uploads.count + downloads.count < transferLimits.maximumAccountTransfers,
              payload.metadata.byteSize <= transferLimits.maximumAccountBytes - bytes else {
            throw ServiceFailure.overloaded
        }
        let descriptor = UploadTransfer(
            id: ServiceTransferID(UUID().uuidString),
            expiresAt: transferNow().addingTimeInterval(transferLimits.lifetime),
            chunkSize: ServiceBinaryLimits.maximumChunkBytes, byteSize: payload.metadata.byteSize
        )
        guard let files = transferStorage else { throw ServiceFailure.unsupportedOperation }
        var slot = UploadSlot(owner: owner, request: payload, descriptor: descriptor)
        do {
            try files.create(descriptor.id, maximumBytes: payload.metadata.byteSize)
        } catch {
            // A partially created file whose cleanup failed still owns quota.
            // Retain its handle even when the caller never received allocation.
            slot.retired = true
            uploads[descriptor.id] = slot
            startUploadExpiry()
            throw error
        }
        uploads[descriptor.id] = slot
        startUploadExpiry()
        return descriptor
    }

    private func validateUpload(_ payload: BeginUploadTransfer) throws {
        let metadata = payload.metadata
        guard metadata.byteSize >= 0, metadata.byteSize <= transferLimits.maximumFileBytes,
              !metadata.name.isEmpty, metadata.name.utf8.count <= 1024,
              !metadata.contentType.isEmpty, metadata.contentType.utf8.count <= 256,
              !metadata.contentType.contains(where: \.isNewline),
              !payload.operationID.rawValue.isEmpty, payload.operationID.rawValue.utf8.count <= 128,
              metadata.width.map({ (1 ... 100_000).contains($0) }) ?? true,
              metadata.height.map({ (1 ... 100_000).contains($0) }) ?? true else {
            throw ServiceFailure.invalidRequest
        }
    }

    func authorizeUploadConversation(
        _ conversation: Conversation.ID, backend: any ChatBackend, epoch: UUID
    ) async throws {
        for _ in 0 ..< 3 {
            guard try storage.conversation(conversation) != nil else { throw ServiceFailure.notAuthorized }
            let version = historyVersions[conversation]
            let world = historyWorldVersion
            let membership = try await withProviderWork(epoch: currentEpoch) { [record] in
                try await backend.membership(of: record.selfID, in: conversation)
            }
            try checkEpoch(epoch)
            guard version == historyVersions[conversation], world == historyWorldVersion else { continue }
            guard membership == .member, try storage.conversation(conversation) != nil else {
                throw ServiceFailure.notAuthorized
            }
            return
        }
        throw ServiceFailure.overloaded
    }

    func currentUpload(_ id: ServiceTransferID, owner: TransferOwner) throws -> UploadSlot {
        guard let slot = uploads[id] else { throw ServiceFailure.transferExpired }
        guard slot.owner == owner else { throw ServiceFailure.notAuthorized }
        guard !slot.retired, slot.descriptor.expiresAt > transferNow() else {
            throw ServiceFailure.transferExpired
        }
        guard try storage.conversation(slot.request.conversationID) != nil else {
            throw ServiceFailure.notAuthorized
        }
        return slot
    }

    func writeUpload(_ request: WriteTransferChunk, body: Data, context: ServiceSessionContext) throws
        -> TransferChunkReceipt {
        let id = request.transferID
        var slot = try currentUpload(id, owner: TransferOwner(context))
        guard slot.job == nil, let files = transferStorage else { throw ServiceFailure.operationConflict }
        guard request.offset <= Int64(slot.received),
              request.offset + Int64(body.count) <= Int64(slot.request.metadata.byteSize) else {
            throw ServiceFailure.invalidRequest
        }
        let next = request.offset + Int64(body.count)
        if request.offset < Int64(slot.received) {
            guard next <= Int64(slot.received),
                  try files.read(id, at: request.offset, count: body.count) == body
            else { throw ServiceFailure.operationConflict }
        } else {
            do {
                try files.append(body, to: id, at: request.offset)
            } catch {
                slot.retired = true
                uploads[id] = slot
                throw error
            }
            slot.received += body.count
            uploads[id] = slot
        }
        return TransferChunkReceipt(
            transferID: id, nextOffset: next, isComplete: next == Int64(slot.request.metadata.byteSize)
        )
    }

    func cancelUpload(_ id: ServiceTransferID, owner: TransferOwner) async throws {
        guard var slot = uploads[id] else { return }
        guard slot.owner == owner else { throw ServiceFailure.notAuthorized }
        slot.retired = true
        uploads[id] = slot
        slot.job?.cancel()
        _ = await slot.job?.result
        try retireUpload(id)
    }

    func retireUpload(_ id: ServiceTransferID) throws {
        guard uploads[id] != nil else { return }
        uploads[id]?.retired = true
        try transferStorage?.remove(id)
        uploads[id] = nil
        if uploads.isEmpty, downloads.isEmpty {
            uploadExpiry?.cancel(); uploadExpiry = nil
        }
    }

    func expireUploads() async throws {
        try await expireDownloads()
        let expired = uploads.filter { $0.value.retired || $0.value.descriptor.expiresAt <= transferNow() }
        for (id, slot) in expired {
            try await cancelUpload(id, owner: slot.owner)
        }
    }

    func startUploadExpiry() {
        guard uploadExpiry == nil else { return }
        uploadExpiry = Task { [weak self, transferLimits] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(min(30, transferLimits.lifetime)))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                do {
                    try await expireUploads()
                } catch {
                    await reportUploadCleanupFailure()
                }
                if await transfersAreEmpty {
                    return
                }
            }
        }
    }

    func reportUploadCleanupFailure() async {
        do {
            try appendAndPublish(
                .backendError(.unknown("Temporary upload files could not be removed.")),
                live: false
            )
        } catch { await quarantine(.storage) }
    }
}
