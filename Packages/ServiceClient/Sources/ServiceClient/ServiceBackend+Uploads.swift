import ChatAPI
import ChatKit
import Foundation

public extension ServiceBackend {
    func uploadAttachment(
        _ attachment: OutgoingAttachment, to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        guard capabilities.canSendAttachments else { throw ServiceFailure.unsupportedOperation }
        guard uploadTasks.count < 8 else { throw ServiceFailure.overloaded }
        let generation = connectionGeneration
        let id = UUID()
        let work = Task { try await uploadFile(
            attachment,
            to: conversation,
            generation: generation,
            progress: progress
        ) }
        uploadTasks[id] = work
        defer { uploadTasks[id] = nil }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

extension ServiceBackend {
    private func uploadFile(
        _ attachment: OutgoingAttachment, to conversation: Conversation.ID, generation: UUID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        try checkUploadGeneration(generation)
        guard attachment.file.isFileURL, attachment.byteSize >= 0 else { throw ServiceFailure.invalidRequest }
        let source = try FileHandle(forReadingFrom: attachment.file)
        defer { try? source.close() }
        guard try source.seekToEnd() == UInt64(attachment.byteSize)
        else { throw ServiceFailure.invalidRequest }
        try source.seek(toOffset: 0)
        let metadata = UploadFileMetadata(
            name: attachment.name, contentType: attachment.contentType, byteSize: attachment.byteSize,
            width: attachment.width, height: attachment.height
        )
        let transfer = try await call(BeginUploadTransfer(
            operationID: ServiceOperationID(UUID().uuidString), conversationID: conversation,
            metadata: metadata
        ))
        do {
            try checkUploadGeneration(generation)
            guard transfer.byteSize == attachment.byteSize, transfer.chunkSize >= 1,
                  transfer.chunkSize <= ServiceBinaryLimits.maximumChunkBytes,
                  !transfer.id.rawValue.isEmpty, transfer.id.rawValue.utf8.count <= 128 else {
                throw ServiceFailure.invalidResponse
            }
            try await writeUploadSource(
                source,
                transfer: transfer,
                generation: generation,
                progress: progress
            )
            // A growing/shrinking source is refused rather than silently truncated.
            guard try source.read(upToCount: 1)?.isEmpty != false else { throw ServiceFailure.invalidRequest }
            let result = try await finalizeFile(transfer.id, generation: generation)
            try checkUploadGeneration(generation)
            return result
        } catch {
            let cleanup = Task { [self] in _ = try? await call(
                CancelTransfer(transferID: transfer.id),
                timeout: 5
            ) }
            await cleanup.value
            throw error
        }
    }

    private func writeUploadSource(
        _ source: FileHandle, transfer: UploadTransfer, generation: UUID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        guard let binary = transport as? any ServiceBinaryTransport, let accountRevision else {
            throw ServiceFailure.unsupportedOperation
        }
        var sent = 0
        progress(AttachmentProgress(bytesReceived: 0, totalBytes: transfer.byteSize))
        while sent < transfer.byteSize {
            try checkUploadGeneration(generation)
            let count = min(transfer.chunkSize, transfer.byteSize - sent)
            let bytes = try source.read(upToCount: count) ?? Data()
            guard bytes.count == count else { throw ServiceFailure.invalidRequest }
            let request = try ServiceRequest(header: ServiceRequestHeader(
                requestID: ServiceRequestID(UUID().uuidString), accountID: accountID,
                accountRevision: accountRevision, deadline: Date().addingTimeInterval(10)
            ), payload: WriteTransferChunk(transferID: transfer.id, offset: Int64(sent), count: count))
            let reply = try await binary.exchangeBinary(request, body: bytes)
            let receipt = try reply.response.value(for: WriteTransferChunk.self)
            try checkUploadGeneration(generation)
            sent += count
            guard receipt.nextOffset == Int64(sent), receipt.isComplete == (sent == transfer.byteSize) else {
                throw ServiceFailure.invalidResponse
            }
            progress(AttachmentProgress(bytesReceived: sent, totalBytes: transfer.byteSize))
        }
    }

    private func finalizeFile(_ id: ServiceTransferID, generation: UUID) async throws -> Attachment {
        let operation = ServiceOperationID(UUID().uuidString)
        do {
            return try await call(FinalizeUploadTransfer(transferID: id, operationID: operation))
        } catch {
            try checkUploadGeneration(generation)
            // A lost finalization reply never dispatches the upload a second time.
            if let status = try? await call(GetOperation(operationID: operation), timeout: 10),
               status.state == "succeeded", let result = status.result {
                return try ServiceCodec.decode(Attachment.self, from: result)
            }
            throw error
        }
    }

    private func checkUploadGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
    }
}
