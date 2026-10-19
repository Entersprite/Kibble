import ChatAPI
import ChatKit
import Foundation

extension ServiceBackend {
    func readDownload(
        _ transfer: DownloadTransfer, destination: URL?, generation: UUID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Data {
        guard let size = transfer.byteSize else { throw ServiceFailure.invalidResponse }
        var output: FileHandle?
        var ownsOutput = false
        var complete = false
        defer {
            try? output?.close()
            if ownsOutput, !complete, let destination {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try checkMediaGeneration(generation)
        if let destination {
            try Data().write(to: destination, options: .withoutOverwriting)
            ownsOutput = true
            output = try FileHandle(forWritingTo: destination)
        }
        var data = Data()
        var offset = 0
        progress(AttachmentProgress(bytesReceived: 0, totalBytes: size))
        while offset < size {
            try checkMediaGeneration(generation)
            let reply = try await readMediaChunk(transfer, at: offset, generation: generation)
            let count = min(transfer.chunkSize, size - offset)
            guard reply.body.count == count else { throw ServiceFailure.invalidResponse }
            let receipt = try reply.response.value(for: ReadTransferChunk.self)
            offset += count
            guard receipt.isComplete == (offset == size) else { throw ServiceFailure.invalidResponse }
            if let output {
                try output.write(contentsOf: reply.body)
            } else {
                data.append(reply.body)
            }
            progress(AttachmentProgress(bytesReceived: offset, totalBytes: size))
        }
        try checkMediaGeneration(generation)
        complete = true
        return data
    }

    private func readMediaChunk(
        _ transfer: DownloadTransfer, at offset: Int, generation: UUID
    ) async throws -> ServiceBinaryReply {
        guard let binary = transport as? any ServiceBinaryTransport, let accountRevision else {
            throw ServiceFailure.unsupportedOperation
        }
        let request = try ServiceRequest(header: ServiceRequestHeader(
            requestID: .init(UUID().uuidString), accountID: accountID, accountRevision: accountRevision,
            deadline: Date().addingTimeInterval(10)
        ), payload: ReadTransferChunk(
            transferID: transfer.id, offset: Int64(offset), count: min(
                transfer.chunkSize,
                (transfer.byteSize ?? 0) - offset
            )
        ))
        let reply = try await binary.exchangeBinary(request, body: Data())
        try checkMediaGeneration(generation)
        try reply.validateChunk(for: request)
        _ = try reply.response.value(for: ReadTransferChunk.self)
        return reply
    }
}
