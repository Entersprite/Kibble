import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func finalizeUpload(
        _ payload: FinalizeUploadTransfer, request: ServiceRequest, backend: any ChatBackend,
        context: ServiceSessionContext, epoch: UUID
    ) async throws -> JSONValue {
        if let previous = try storage.operation(payload.operationID) {
            // Reserve also compares the complete original request payload.
            _ = try storage.reserve(payload.operationID, request: request)
            switch previous.state {
            case "succeeded":
                guard let result = previous.result else { throw ServiceFailure.invalidResponse }
                return result
            case "failed": throw previous.failure ?? ServiceFailure.internalFailure
            case "accepted": break
            default: throw ServiceFailure.operationUnknown
            }
        }
        let id = payload.transferID
        var slot = try currentUpload(id, owner: TransferOwner(context))
        guard slot.received == slot.request.metadata.byteSize else { throw ServiceFailure.invalidRequest }
        if let operation = slot.operation,
           operation != payload.operationID {
            throw ServiceFailure.operationConflict
        }
        if let job = slot.job {
            return try await job.value
        }
        slot.operation = payload.operationID
        let job = Task { [self] in
            try await finishUploadProvider(
                payload,
                request: request,
                backend: backend,
                context: context,
                epoch: epoch
            )
        }
        slot.job = job
        uploads[id] = slot
        let result = try await withTaskCancellationHandler {
            try await job.value
        } onCancel: { job.cancel() }
        // A post-ack cleanup failure cannot turn an accepted upload into a retry.
        do { try retireUpload(id) } catch { await reportUploadCleanupFailure() }
        return result
    }

    private func finishUploadProvider(
        _ payload: FinalizeUploadTransfer, request: ServiceRequest, backend: any ChatBackend,
        context: ServiceSessionContext, epoch: UUID
    ) async throws -> JSONValue {
        let id = payload.transferID
        let owner = TransferOwner(context)
        let slot = try currentUpload(id, owner: owner)
        try await authorizeUploadConversation(slot.request.conversationID, backend: backend, epoch: epoch)
        guard let files = transferStorage, storage is any ServiceUploadReferences else {
            throw ServiceFailure.unsupportedOperation
        }
        _ = try currentUpload(id, owner: owner)
        let metadata = slot.request.metadata
        let providerProgress = slot.providerProgress
        let file = try files.file(id, expectedBytes: metadata.byteSize)
        let staged = OutgoingAttachment(
            id: id.rawValue, file: file, name: metadata.name, contentType: metadata.contentType,
            byteSize: metadata.byteSize, width: metadata.width, height: metadata.height
        )
        return try await performOperation(
            payload.operationID, request: request, epoch: epoch,
            authorize: { _ = try currentUpload(id, owner: owner) }, perform: {
                let attachment = try await backend.uploadAttachment(
                    staged, to: slot.request.conversationID,
                    progress: { [providerProgress, maximum = metadata.byteSize] update in
                        providerProgress.record(update.bytesReceived, maximum: maximum)
                    }
                )
                try await commitUploadReference(attachment, id: id, owner: owner, epoch: epoch)
                return attachment
            }
        )
    }

    private func commitUploadReference(
        _ attachment: Attachment, id: ServiceTransferID, owner: TransferOwner, epoch: UUID
    ) throws {
        // No await separates the lifecycle fence from this canonical write.
        try checkEpoch(epoch)
        let slot = try currentUpload(id, owner: owner)
        guard let references = storage as? any ServiceUploadReferences else {
            throw ServiceFailure.unsupportedOperation
        }
        let date = transferNow()
        try references.rememberUpload(
            attachment, in: slot.request.conversationID, at: date, until: date.addingTimeInterval(86400)
        )
    }

    func authorizeUploadedAttachments(_ command: ChatCommand) throws {
        guard case let .sendMessage(conversation, _, _, _, attachments, _, _) = command,
              !attachments.isEmpty else { return }
        guard let references = storage as? any ServiceUploadReferences
        else { throw ServiceFailure.notAuthorized }
        for attachment in attachments {
            guard try references
                .uploadedAttachment(attachment.id, in: conversation, at: transferNow()) == attachment
            else { throw ServiceFailure.notAuthorized }
        }
    }
}
