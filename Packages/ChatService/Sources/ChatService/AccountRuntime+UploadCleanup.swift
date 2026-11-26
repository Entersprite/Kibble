import Foundation

extension AccountRuntime {
    func cancelUploadJobs() -> Task<Void, Never>? {
        uploadExpiry?.cancel()
        for slot in downloads.values {
            slot.job?.cancel()
        }
        for slot in uploads.values {
            slot.job?.cancel()
        }
        return uploadExpiry
    }

    func closeUploadStorage() async {
        let jobs = downloads.values.compactMap(\.job)
        for job in jobs {
            await job.value
        }
        do {
            try transferStorage?.close()
        } catch {
            await reportUploadCleanupFailure()
        }
        // A refused cleanup keeps its disk reservation in the host factory.
        // The next owned open/removal retries it before admitting new files.
        transferStorage = nil
        uploads.removeAll()
        downloads.removeAll()
        uploadExpiry = nil
    }
}
