import ChatAPI
import ChatKit
import Foundation

extension ServiceBackend {
    func downloadMedia(
        _ payload: BeginDownloadTransfer, destination: URL?, generation: UUID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Data {
        try checkMediaGeneration(generation)
        progress(AttachmentProgress(bytesReceived: 0, totalBytes: nil))
        let initial = try await call(payload)
        let result: Result<Data, any Error>
        do {
            try validateDownload(initial, maximum: payload.maximumBytes)
            let ready = try await awaitDownload(initial, generation: generation)
            result = try await .success(readDownload(
                ready,
                destination: destination,
                generation: generation,
                progress: progress
            ))
        } catch { result = .failure(error) }
        // Cleanup is independently owned even if the calling task was cancelled.
        let cleanup = Task { [self] in
            _ = try? await call(CancelTransfer(transferID: initial.id), timeout: 5)
        }
        await cleanup.value
        return try result.get()
    }

    private func awaitDownload(
        _ initial: DownloadTransfer,
        generation: UUID
    ) async throws -> DownloadTransfer {
        var value = initial
        while value.phase == "fetching" {
            try checkMediaGeneration(generation)
            guard value.expiresAt > Date() else { throw ServiceFailure.transferExpired }
            value = try await call(GetDownloadTransfer(transferID: initial.id), timeout: 10)
            try validateDownload(value, maximum: initial.maximumBytes)
            guard value.id == initial.id, value.expiresAt == initial.expiresAt,
                  value.maximumBytes == initial.maximumBytes, value.chunkSize == initial.chunkSize else {
                throw ServiceFailure.invalidResponse
            }
            if value.phase == "fetching" {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try checkMediaGeneration(generation)
        guard value.phase == "ready", value.byteSize != nil else { throw ServiceFailure.invalidResponse }
        return value
    }

    private func validateDownload(_ value: DownloadTransfer, maximum: Int) throws {
        guard !value.id.rawValue.isEmpty, value.id.rawValue.utf8.count <= 128,
              value.maximumBytes >= 0, value.maximumBytes <= maximum,
              value.chunkSize > 0, value.chunkSize <= ServiceBinaryLimits.maximumChunkBytes,
              value.phase == "fetching" || value.phase == "ready",
              value.byteSize.map({ $0 >= 0 && $0 <= value.maximumBytes }) ?? (value.phase == "fetching")
        else {
            throw ServiceFailure.invalidResponse
        }
    }
}
