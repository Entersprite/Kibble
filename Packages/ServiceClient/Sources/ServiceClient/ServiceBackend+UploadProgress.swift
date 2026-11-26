import ChatAPI
import ChatKit
import Foundation

extension ServiceBackend {
    func finalizeFile(
        _ transfer: UploadTransfer, generation: UUID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        let observer = Task {
            await observeUploadProgress(transfer, generation: generation, progress: progress)
        }
        let result: Result<Attachment, any Error>
        do {
            result = try await .success(submitUploadFinalization(transfer.id, generation: generation))
        } catch { result = .failure(error) }
        observer.cancel()
        await observer.value
        try checkUploadGeneration(generation)
        let attachment = try result.get()
        progress(AttachmentProgress(bytesReceived: transfer.byteSize * 2, totalBytes: transfer.byteSize * 2))
        return attachment
    }

    /// Report both byte-transfer legs as one monotonic total. Staging alone is
    /// half complete; only an acknowledged finalization reaches the full total.
    /// Progress is advisory and cannot replace the durable finalization outcome.
    private func observeUploadProgress(
        _ transfer: UploadTransfer, generation: UUID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async {
        var projection = UploadProgressProjection(transfer: transfer)
        do {
            while true {
                try checkUploadGeneration(generation)
                let status = try await call(GetUploadTransfer(transferID: transfer.id), timeout: 5)
                try checkUploadGeneration(generation)
                if let update = try projection.accept(status) {
                    progress(update)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            // Retirement, unsupported progress and transport failure stop this
            // advisory observer. The original operation still determines outcome.
        }
    }
}

struct UploadProgressProjection {
    let transfer: UploadTransfer
    private var published = 0

    init(transfer: UploadTransfer) {
        self.transfer = transfer
    }

    mutating func accept(_ status: UploadTransferStatus) throws -> AttachmentProgress? {
        guard status.transfer == transfer, status.stagedBytes == transfer.byteSize,
              status.phase == "receiving" || status.phase == "uploading",
              (0 ... transfer.byteSize).contains(status.providerBytesSent),
              status.phase != "receiving" || status.providerBytesSent == 0 else {
            throw ServiceFailure.invalidResponse
        }
        let count = min(status.providerBytesSent, max(0, transfer.byteSize - 1))
        guard count > published else { return nil }
        published = count
        return AttachmentProgress(bytesReceived: transfer.byteSize + count, totalBytes: transfer.byteSize * 2)
    }
}
