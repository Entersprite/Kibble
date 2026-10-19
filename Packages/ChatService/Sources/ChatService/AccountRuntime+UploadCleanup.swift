import Foundation

extension AccountRuntime {
    func cancelUploadJobs() -> Task<Void, Never>? {
        uploadExpiry?.cancel()
        for slot in uploads.values {
            slot.job?.cancel()
        }
        return uploadExpiry
    }

    func closeUploadStorage() async {
        do {
            try transferStorage?.close()
        } catch {
            await reportUploadCleanupFailure()
        }
        // A refused cleanup keeps its disk reservation in the host factory.
        // The next owned open/removal retries it before admitting new files.
        transferStorage = nil
        uploads.removeAll()
        uploadExpiry = nil
    }
}
